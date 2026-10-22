#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/utsname.h>
#include "sqlite3.h"
#include "zlib.h"

#ifndef S32_BUILD_ID
#define S32_BUILD_ID "unrecorded"
#endif
#define INPUT_BYTES 65536U
#define ROWS 1024U
#define LOOKUPS 128U
static unsigned char input[INPUT_BYTES], restored[INPUT_BYTES];

static void fail(const char *message) {
    fprintf(stderr, "S32_WORKLOAD_ERROR %s\n", message);
    exit(1);
}
static uint64_t now_ns(void) {
    struct timespec stamp;
    if (clock_gettime(CLOCK_MONOTONIC, &stamp)) fail("clock_gettime");
    return (uint64_t)stamp.tv_sec * 1000000000ULL + (uint64_t)stamp.tv_nsec;
}
static uint64_t elapsed(uint64_t start) {
    uint64_t end = now_ns();
    if (end <= start) fail("nonpositive elapsed time");
    return end - start;
}
static uint32_t fnv1a(const unsigned char *data, size_t size) {
    uint32_t hash = 2166136261U;
    while (size--) hash = (hash ^ *data++) * 16777619U;
    return hash;
}
static void make_input(void) {
    static const char text[] = "synapse32 sensor log: temperature=024 pressure=1013 state=ready\n";
    uint32_t random = 0x12345678U;
    for (unsigned i = 0; i < INPUT_BYTES; ++i) {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        input[i] = i % 257U < 224U ? (unsigned char)text[i % (sizeof(text) - 1)] : (unsigned char)random;
    }
}
static void record(const char *name, unsigned iterations, uint64_t duration,
                   uint64_t units, uint64_t checksum, uint64_t output_bytes) {
    printf("S32_WORKLOAD {\"schema\":1,\"case\":\"%s\",\"iterations\":%u,"
           "\"elapsed_ns\":%" PRIu64 ",\"units\":%" PRIu64 ",\"checksum\":%" PRIu64
           ",\"output_bytes\":%" PRIu64 ",\"validated\":true}\n",
           name, iterations, duration, units, checksum, output_bytes);
    fflush(stdout);
}
static void compression(unsigned iterations) {
    uLong bound = compressBound(INPUT_BYTES), compressed_size = bound;
    unsigned char *compressed = malloc(bound);
    if (!compressed) fail("compression allocation");
    make_input();
    uint32_t checksum = fnv1a(input, sizeof(input));
    uint64_t duration = 0;
    for (unsigned i = 0; i < iterations; ++i) {
        compressed_size = bound;
        uint64_t start = now_ns();
        int result = compress2(compressed, &compressed_size, input, INPUT_BYTES, 6);
        duration += elapsed(start);
        if (result != Z_OK) fail("compress2");
        uLong size = INPUT_BYTES;
        if (uncompress(restored, &size, compressed, compressed_size) != Z_OK ||
            size != INPUT_BYTES || memcmp(restored, input, INPUT_BYTES)) fail("compression roundtrip");
    }
    record("zlib_compress", iterations, duration, (uint64_t)INPUT_BYTES * iterations,
           checksum, compressed_size);
    duration = 0;
    unsigned decompressions = iterations * 16U;
    for (unsigned i = 0; i < decompressions; ++i) {
        uLong size = INPUT_BYTES;
        uint64_t start = now_ns();
        int result = uncompress(restored, &size, compressed, compressed_size);
        duration += elapsed(start);
        if (result != Z_OK || size != INPUT_BYTES || memcmp(restored, input, INPUT_BYTES))
            fail("decompression roundtrip");
    }
    record("zlib_decompress", decompressions, duration, (uint64_t)INPUT_BYTES * decompressions,
           fnv1a(restored, sizeof(restored)), INPUT_BYTES);
    free(compressed);
}
static void sql_exec(sqlite3 *db, const char *sql) {
    char *error = NULL;
    if (sqlite3_exec(db, sql, NULL, NULL, &error) != SQLITE_OK) {
        fprintf(stderr, "SQLite: %s\n", error ? error : sqlite3_errmsg(db));
        sqlite3_free(error);
        fail("sqlite3_exec");
    }
}
static sqlite3_stmt *prepare(sqlite3 *db, const char *sql) {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &statement, NULL) != SQLITE_OK) fail("sqlite3_prepare");
    return statement;
}
static void finish(sqlite3_stmt *statement) {
    if (sqlite3_finalize(statement) != SQLITE_OK) fail("sqlite3_finalize");
}
static unsigned value(unsigned id) { return (id * 37U + 11U) % 1000U; }
static void database(unsigned iterations) {
    sqlite3 *db = NULL;
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) fail("sqlite3_open");
    sql_exec(db, "PRAGMA temp_store=MEMORY; PRAGMA journal_mode=MEMORY;"
                 "CREATE TABLE samples(id INTEGER PRIMARY KEY, grp INTEGER NOT NULL, value INTEGER NOT NULL)");
    uint64_t duration = 0, expected_sum = 0, expected_join = 0;
    uint64_t group_sums[16] = {0};
    for (unsigned i = 0; i < ROWS; ++i) {
        expected_sum += value(i);
        expected_join += (uint64_t)value(i) * value((i + 1) % ROWS);
        group_sums[i % 16] += value(i);
    }
    sqlite3_stmt *insert = prepare(db, "INSERT INTO samples VALUES(?1,?2,?3)");
    for (unsigned iteration = 0; iteration < iterations; ++iteration) {
        sql_exec(db, "DELETE FROM samples");
        uint64_t start = now_ns();
        sql_exec(db, "BEGIN");
        for (unsigned i = 0; i < ROWS; ++i) {
            if (sqlite3_bind_int(insert, 1, (int)i) != SQLITE_OK ||
                sqlite3_bind_int(insert, 2, (int)(i % 16)) != SQLITE_OK ||
                sqlite3_bind_int(insert, 3, (int)value(i)) != SQLITE_OK ||
                sqlite3_step(insert) != SQLITE_DONE || sqlite3_reset(insert) != SQLITE_OK)
                fail("sqlite insert");
        }
        sql_exec(db, "COMMIT");
        duration += elapsed(start);
        sqlite3_stmt *check = prepare(db, "SELECT count(*),sum(value) FROM samples");
        if (sqlite3_step(check) != SQLITE_ROW || sqlite3_column_int(check, 0) != ROWS ||
            sqlite3_column_int64(check, 1) != (sqlite3_int64)expected_sum ||
            sqlite3_step(check) != SQLITE_DONE) fail("sqlite insert validation");
        finish(check);
    }
    finish(insert);
    record("sqlite_insert", iterations, duration, (uint64_t)ROWS * iterations, expected_sum, 0);
    /* Query preparation is excluded; execution, reset and result consumption are timed. */
    sqlite3_stmt *lookup = prepare(db, "SELECT value FROM samples WHERE id=?1");
    sqlite3_stmt *group = prepare(db, "SELECT grp,sum(value),count(*) FROM samples GROUP BY grp ORDER BY grp");
    sqlite3_stmt *join = prepare(db, "SELECT sum(a.value*b.value) FROM samples a JOIN samples b ON b.id=(a.id+1)%1024");
    uint64_t expected_lookup = 0, checksum = 0;
    for (unsigned i = 0; i < LOOKUPS; ++i) expected_lookup += value((i * 17U) % ROWS);
    uint64_t expected = (expected_lookup + expected_sum + ROWS + expected_join) * iterations;
    duration = 0;
    for (unsigned iteration = 0; iteration < iterations; ++iteration) {
        uint64_t start = now_ns();
        for (unsigned i = 0; i < LOOKUPS; ++i) {
            unsigned id = (i * 17U) % ROWS;
            if (sqlite3_bind_int(lookup, 1, (int)id) != SQLITE_OK || sqlite3_step(lookup) != SQLITE_ROW ||
                sqlite3_column_int(lookup, 0) != (int)value(id)) fail("sqlite point query validation");
            checksum += (uint64_t)sqlite3_column_int64(lookup, 0);
            if (sqlite3_step(lookup) != SQLITE_DONE || sqlite3_reset(lookup) != SQLITE_OK) fail("sqlite lookup reset");
        }
        for (unsigned i = 0; i < 16; ++i) {
            if (sqlite3_step(group) != SQLITE_ROW || sqlite3_column_int(group, 0) != (int)i ||
                sqlite3_column_int64(group, 1) != (sqlite3_int64)group_sums[i] ||
                sqlite3_column_int(group, 2) != ROWS / 16) fail("sqlite group validation");
            checksum += (uint64_t)sqlite3_column_int64(group, 1) + (uint64_t)sqlite3_column_int64(group, 2);
        }
        if (sqlite3_step(group) != SQLITE_DONE || sqlite3_reset(group) != SQLITE_OK ||
            sqlite3_step(join) != SQLITE_ROW || sqlite3_column_int64(join, 0) != (sqlite3_int64)expected_join)
            fail("sqlite join validation");
        checksum += (uint64_t)sqlite3_column_int64(join, 0);
        if (sqlite3_step(join) != SQLITE_DONE || sqlite3_reset(join) != SQLITE_OK) fail("sqlite join reset");
        duration += elapsed(start);
    }
    if (checksum != expected) fail("sqlite query checksum");
    finish(lookup); finish(group); finish(join);
    record("sqlite_queries", iterations, duration, (LOOKUPS + 2ULL) * iterations, checksum, 0);
    if (sqlite3_close(db) != SQLITE_OK) fail("sqlite3_close");
}
int main(int argc, char **argv) {
    unsigned iterations = 3;
    if (argc == 2) {
        char *end = NULL;
        errno = 0;
        unsigned long count = strtoul(argv[1], &end, 10);
        if (errno || end == argv[1] || *end || count < 1 || count > 100) fail("iterations must be 1..100");
        iterations = (unsigned)count;
    } else if (argc != 1) fail("usage: workloads [iterations=3]");
    struct utsname kernel;
    if (uname(&kernel)) fail("uname");
    printf("S32_WORKLOAD_CONFIG {\"schema\":1,\"build_id\":\"%s\",\"zlib\":\"%s\","
           "\"sqlite\":\"%s\",\"sqlite_source_id\":\"%s\",\"kernel\":\"%s\",\"machine\":\"%s\","
           "\"iterations\":%u,\"input_bytes\":%u,\"compression_level\":6,\"rows\":%u,"
           "\"database\":\"memory\",\"clock\":\"CLOCK_MONOTONIC\"}\n",
           S32_BUILD_ID, zlibVersion(), sqlite3_libversion(), sqlite3_sourceid(),
           kernel.release, kernel.machine, iterations, INPUT_BYTES, ROWS);
    fflush(stdout);
    compression(iterations);
    database(iterations);
    puts("S32_WORKLOAD_DONE 0");
    return 0;
}

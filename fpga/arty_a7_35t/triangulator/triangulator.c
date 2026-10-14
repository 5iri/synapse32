/* Convex-hull triangulation and integer Delaunay edge flips on Synapse32. */
#include <stdint.h>

#define MAX_POINTS 64
#define MAX_TRIANGLES (2 * MAX_POINTS + 8)
#define WIDTH 640
#define HEIGHT 400

typedef struct { int32_t x, y; } Point;
typedef struct { int32_t a, b, c; } Triangle;

static int64_t orientation(Point a, Point b, Point c)
{
    return (int64_t)(b.x - a.x) * (c.y - a.y)
         - (int64_t)(b.y - a.y) * (c.x - a.x);
}

static int inside_circle(Point a, Point b, Point c, Point p)
{
    int64_t ax = a.x - p.x, ay = a.y - p.y;
    int64_t bx = b.x - p.x, by = b.y - p.y;
    int64_t cx = c.x - p.x, cy = c.y - p.y;
    int64_t determinant = (ax * ax + ay * ay) * (bx * cy - by * cx)
                        - (bx * bx + by * by) * (ax * cy - ay * cx)
                        + (cx * cx + cy * cy) * (ax * by - ay * bx);
    return determinant > 0; /* All triangles have positive orientation. */
}

static Triangle positive_triangle(const Point *points, int a, int b, int c)
{
    if (orientation(points[a], points[b], points[c]) < 0) {
        int swap = a; a = b; b = swap;
    }
    return (Triangle){a, b, c};
}

static void map_triangle(int16_t *neighbors, int count, Triangle triangle, int index)
{
    neighbors[triangle.a * count + triangle.b] = index;
    neighbors[triangle.b * count + triangle.c] = index;
    neighbors[triangle.c * count + triangle.a] = index;
}

/* Coordinates must be in the 640x400 viewport; predicates fit signed 64 bits.
 * Starting from the real convex hull avoids finite supertriangle vertices
 * suppressing thin hull triangles whose circumcircles extend far away.
 */
int triangulate(const Point *points, int count, Triangle *result)
{
    int order[MAX_POINTS], hull[2 * MAX_POINTS];
    int16_t neighbors[MAX_POINTS * MAX_POINTS];
    if (count < 3 || count > MAX_POINTS) return -1;
    for (int i = 0; i < count; ++i) {
        if (points[i].x < 0 || points[i].x > WIDTH ||
            points[i].y < 0 || points[i].y > HEIGHT) return -1;
        int j = i;
        while (j && (points[order[j - 1]].x > points[i].x ||
               (points[order[j - 1]].x == points[i].x && points[order[j - 1]].y > points[i].y))) {
            order[j] = order[j - 1];
            --j;
        }
        order[j] = i;
    }
    int distinct = 0;
    for (int i = 0; i < count; ++i) {
        if (!distinct || points[order[i]].x != points[order[distinct - 1]].x ||
                         points[order[i]].y != points[order[distinct - 1]].y)
            order[distinct++] = order[i];
    }
    if (distinct < 3) return 0;
    int h = 0;
    for (int i = 0; i < distinct; ++i) {
        while (h >= 2 && orientation(points[hull[h - 2]], points[hull[h - 1]], points[order[i]]) <= 0) --h;
        hull[h++] = order[i];
    }
    int upper_start = h + 1;
    for (int i = distinct - 2; i >= 0; --i) {
        while (h >= upper_start && orientation(points[hull[h - 2]], points[hull[h - 1]], points[order[i]]) <= 0) --h;
        hull[h++] = order[i];
    }
    --h;
    if (h < 3) return 0;
    int used = 0;
    for (int i = 1; i + 1 < h; ++i)
        result[used++] = (Triangle){hull[0], hull[i], hull[i + 1]};

    for (int p = 0; p < count; ++p) {
        int present = 0;
        for (int t = 0; t < used && !present; ++t) {
            int vertices[3] = {result[t].a, result[t].b, result[t].c};
            for (int e = 0; e < 3; ++e)
                if (points[vertices[e]].x == points[p].x && points[vertices[e]].y == points[p].y) present = 1;
        }
        if (present) continue;
        Triangle pieces[6];
        int piece_count = 0;
        for (int t = 0; t < used;) {
            Triangle triangle = result[t];
            int vertices[3] = {triangle.a, triangle.b, triangle.c};
            int64_t directions[3];
            int contained = 1;
            for (int e = 0; e < 3; ++e) {
                directions[e] = orientation(points[vertices[e]], points[vertices[(e + 1) % 3]], points[p]);
                if (directions[e] < 0) contained = 0;
            }
            if (!contained) { ++t; continue; }
            for (int e = 0; e < 3; ++e) {
                if (directions[e] > 0) {
                    if (piece_count == 6) return -1;
                    pieces[piece_count++] = (Triangle){vertices[e], vertices[(e + 1) % 3], p};
                }
            }
            result[t] = result[--used];
        }
        if (!piece_count || used + piece_count > MAX_TRIANGLES) return -1;
        for (int i = 0; i < piece_count; ++i) result[used++] = pieces[i];
    }

    for (int i = 0; i < count * count; ++i) neighbors[i] = -1;
    for (int t = 0; t < used; ++t) map_triangle(neighbors, count, result[t], t);
    int flips = 0;
again:
    for (int t = 0; t < used; ++t) {
        int vertices[3] = {result[t].a, result[t].b, result[t].c};
        for (int e = 0; e < 3; ++e) {
            int a = vertices[e], b = vertices[(e + 1) % 3], c = vertices[(e + 2) % 3];
            int u = neighbors[b * count + a];
            if (u < 0 || u <= t) continue;
            Triangle other = result[u];
            int d = other.a != a && other.a != b ? other.a :
                    other.b != a && other.b != b ? other.b : other.c;
            int64_t first = orientation(points[c], points[d], points[a]);
            int64_t second = orientation(points[c], points[d], points[b]);
            if (!((first > 0 && second < 0) || (first < 0 && second > 0))) continue;
            if (!inside_circle(points[a], points[b], points[c], points[d])) continue;
            if (++flips > 4 * count * count) return -1;
            map_triangle(neighbors, count, result[t], -1);
            map_triangle(neighbors, count, result[u], -1);
            result[t] = positive_triangle(points, c, d, a);
            result[u] = positive_triangle(points, d, c, b);
            map_triangle(neighbors, count, result[t], t);
            map_triangle(neighbors, count, result[u], u);
            goto again;
        }
    }
    return used;
}

#ifndef TRIANGULATOR_KERNEL_ONLY
/* A tiny static Linux executable: no libc, floating point, or heap required. */
static long syscall3(long number, long first, long second, long third)
{
    register long a0 __asm__("a0") = first;
    register long a1 __asm__("a1") = second;
    register long a2 __asm__("a2") = third;
    register long a7 __asm__("a7") = number;
    __asm__ volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a2), "r"(a7) : "memory");
    return a0;
}

static int output(const char *text, unsigned length)
{
    while (length) {
        long written = syscall3(64, 1, (long)text, length);
        if (written == -4) continue; /* EINTR */
        if (written <= 0) return -1;
        text += written;
        length -= written;
    }
    return 0;
}

static char *text(char *cursor, const char *value)
{
    while (*value) *cursor++ = *value++;
    return cursor;
}

static char *number(char *cursor, uint32_t value)
{
    char digits[10];
    int length = 0;
    do { digits[length++] = '0' + value % 10; value /= 10; } while (value);
    while (length) *cursor++ = digits[--length];
    return cursor;
}

static unsigned parse_unsigned(const char *value)
{
    unsigned result = 0;
    if (!*value) return 0;
    while (*value) {
        if (*value < '0' || *value > '9' || result > 1000000) return 0;
        result = result * 10 + *value++ - '0';
    }
    return result;
}

static int equals(const char *a, const char *b)
{
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}

struct timestamp { int64_t seconds, nanoseconds; };
static int now(struct timestamp *stamp)
{
    return syscall3(403, 1, (long)stamp, 0) < 0 ? -1 : 0; /* clock_gettime64 */
}

static uint32_t random_state = 0x532032;
static unsigned random_value(void)
{
    random_state = random_state * 1664525u + 1013904223u;
    return random_state;
}

int demo_main(int argc, char **argv)
{
    unsigned count = 16, frames = 0;
    for (int i = 1; i < argc; ++i) {
        if (i + 1 < argc && equals(argv[i], "--points")) count = parse_unsigned(argv[++i]);
        else if (i + 1 < argc && equals(argv[i], "--frames")) frames = parse_unsigned(argv[++i]);
        else {
            static const char usage[] = "Usage: triangulator [--points 3..64] [--frames N]\n";
            output(usage, sizeof(usage) - 1);
            return 1;
        }
    }
    if (count < 3 || count > MAX_POINTS) return 1;
    Point points[MAX_POINTS], velocity[MAX_POINTS];
    Triangle triangles[MAX_TRIANGLES];
    char line[8192];
    for (unsigned i = 0; i < count; ++i) {
        points[i] = (Point){20 + random_value() % (WIDTH - 40),
                            20 + random_value() % (HEIGHT - 40)};
        velocity[i] = (Point){1 + random_value() % 3, 1 + random_value() % 3};
        if (i & 1) velocity[i].x = -velocity[i].x;
        if (i & 2) velocity[i].y = -velocity[i].y;
    }
    output("\n", 1);
    for (unsigned frame = 0; !frames || frame < frames; ++frame) {
        for (unsigned i = 0; i < count; ++i) {
            points[i].x += velocity[i].x;
            points[i].y += velocity[i].y;
            if (points[i].x < 8 || points[i].x > WIDTH - 8) {
                velocity[i].x = -velocity[i].x;
                points[i].x += 2 * velocity[i].x;
            }
            if (points[i].y < 8 || points[i].y > HEIGHT - 8) {
                velocity[i].y = -velocity[i].y;
                points[i].y += 2 * velocity[i].y;
            }
            /* Avoid coincident vertices without using approximate predicates. */
            for (unsigned j = 0; j < i; ++j) {
                if (points[j].x == points[i].x && points[j].y == points[i].y) {
                    points[i].x = 8 + (points[i].x + 1) % (WIDTH - 16);
                    j = (unsigned)-1;
                }
            }
        }
        struct timestamp start, end;
        if (now(&start)) return 2;
        int triangle_count = triangulate(points, count, triangles);
        if (now(&end) || triangle_count < 0) return 2;
        uint32_t microseconds = (uint32_t)(end.seconds - start.seconds) * 1000000u
                             + (int32_t)(end.nanoseconds - start.nanoseconds) / 1000;
        char *cursor = text(line, "S32MESH {\"frame\":");
        cursor = number(cursor, frame);
        cursor = text(cursor, ",\"compute_us\":");
        cursor = number(cursor, microseconds);
        cursor = text(cursor, ",\"points\":[");
        for (unsigned i = 0; i < count; ++i) {
            if (i) *cursor++ = ',';
            *cursor++ = '['; cursor = number(cursor, points[i].x);
            *cursor++ = ','; cursor = number(cursor, points[i].y); *cursor++ = ']';
        }
        cursor = text(cursor, "],\"triangles\":[");
        for (int i = 0; i < triangle_count; ++i) {
            if (i) *cursor++ = ',';
            *cursor++ = '['; cursor = number(cursor, triangles[i].a);
            *cursor++ = ','; cursor = number(cursor, triangles[i].b);
            *cursor++ = ','; cursor = number(cursor, triangles[i].c); *cursor++ = ']';
        }
        cursor = text(cursor, "]}\n");
        if (output(line, (unsigned)(cursor - line))) return 3;
    }
    output("S32DONE\n", 8);
    return 0;
}

__attribute__((naked, noreturn)) void _start(void)
{
    __asm__ volatile("lw a0, 0(sp)\naddi a1, sp, 4\nandi sp, sp, -16\n"
                     "call demo_main\nli a7, 93\necall\n1: j 1b\n");
}
#endif

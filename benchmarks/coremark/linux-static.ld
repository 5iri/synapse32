/* The official MEM_STATIC byte array is cast directly to list_head*. Keep
 * that array suitably aligned without editing any EEMBC algorithm source.
 * INSERT retains the toolchain's normal ELF layout and alignment rules.
 */
SECTIONS
{
    .coremark_buffer ALIGN(16) (NOLOAD) :
    {
        *(.bss.static_memblk)
    }
}
INSERT BEFORE .bss;

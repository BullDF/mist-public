// scan <binary> <text_fileoff> <text_vmaddr> <text_size> <selref_vmaddr>...
// Prints "<pc> <selref> <reg> <next bl target or 0>" for every adrp+ldr pair
// that loads one of the selrefs. <reg> is the register holding the selector
// at that bl: 2 when the load or a later `mov x2, xN` puts it in x2.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  if (argc < 6) return 2;
  FILE *f = fopen(argv[1], "rb");
  if (!f) return 1;
  uint64_t off = strtoull(argv[2], 0, 0), addr = strtoull(argv[3], 0, 0), size = strtoull(argv[4], 0, 0);
  uint32_t *ins = malloc(size);
  fseek(f, (long)off, SEEK_SET);
  if (fread(ins, 1, size, f) != size) return 1;
  fclose(f);
  int nsel = argc - 5;
  uint64_t *sel = malloc(sizeof(uint64_t) * nsel);
  for (int i = 0; i < nsel; i++) sel[i] = strtoull(argv[5 + i], 0, 0);
  uint64_t n = size / 4;
  for (uint64_t i = 0; i < n; i++) {
    uint32_t a = ins[i];
    if ((a & 0x9F000000) != 0x90000000) continue;
    int rd = a & 31;
    int64_t imm = (int64_t)((((a >> 5) & 0x7FFFF) << 2) | ((a >> 29) & 3));
    if (imm & (1LL << 20)) imm -= (1LL << 21);
    uint64_t page = ((addr + i * 4) & ~0xFFFULL) + (uint64_t)(imm << 12);
    for (uint64_t j = i + 1; j < n && j <= i + 8; j++) {
      uint32_t b = ins[j];
      if ((b & 0xFFC00000) != 0xF9400000 || ((b >> 5) & 31) != rd) continue;
      uint64_t target = page + ((b >> 10) & 0xFFF) * 8;
      int dest = b & 31;
      for (int k = 0; k < nsel; k++) {
        if (sel[k] != target) continue;
        uint64_t bl = 0;
        for (uint64_t m = j + 1; m < n && m <= j + 12; m++) {
          if (dest != 2 && ins[m] == (0xAA0003E2u | ((uint32_t)dest << 16))) dest = 2;
          // A callee-saved register keeps the selector across earlier calls.
          if ((ins[m] & 0xFC000000) == 0x94000000 && dest == 2) {
            int64_t d = ins[m] & 0x3FFFFFF;
            if (d & (1 << 25)) d -= (1 << 26);
            bl = addr + m * 4 + (uint64_t)(d * 4);
            break;
          }
        }
        printf("0x%llx 0x%llx %d 0x%llx\n", (unsigned long long)(addr + j * 4),
               (unsigned long long)target, dest, (unsigned long long)bl);
      }
      break;
    }
  }
  return 0;
}

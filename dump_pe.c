#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#pragma pack(push, 1)
typedef struct {
    uint32_t ImportLookupTableRVA;
    uint32_t TimeDateStamp;
    uint32_t ForwarderChain;
    uint32_t NameRVA;
    uint32_t ImportAddressTableRVA;
} IMAGE_IMPORT_DESCRIPTOR;

typedef struct {
    uint8_t Name[8];
    uint32_t VirtualSize;
    uint32_t VirtualAddress;
    uint32_t SizeOfRawData;
    uint32_t PointerToRawData;
    uint32_t PointerToRelocations;
    uint32_t PointerToLinenumbers;
    uint16_t NumberOfRelocations;
    uint16_t NumberOfLinenumbers;
    uint32_t Characteristics;
} IMAGE_SECTION_HEADER;
#pragma pack(pop)

uint32_t rva_to_offset(uint32_t rva, IMAGE_SECTION_HEADER* sections, int num_sections) {
    for (int i = 0; i < num_sections; i++) {
        if (rva >= sections[i].VirtualAddress && rva < sections[i].VirtualAddress + sections[i].VirtualSize) {
            return sections[i].PointerToRawData + (rva - sections[i].VirtualAddress);
        }
    }
    return 0;
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        printf("Usage: dump_pe <file_path>\n");
        return 1;
    }
    const char* file_path = argv[1];
    FILE* file = fopen(file_path, "rb");
    if (!file) {
        printf("Failed to open file: %s\n", file_path);
        return 1;
    }

    fseek(file, 0, SEEK_END);
    size_t file_size = ftell(file);
    fseek(file, 0, SEEK_SET);

    uint8_t* buffer = malloc(file_size);
    size_t bytes_read = fread(buffer, 1, file_size, file);
    fclose(file);

    if (bytes_read < 64) {
        printf("File too small: %zu bytes\n", bytes_read);
        free(buffer);
        return 1;
    }

    if (buffer[0] != 'M' || buffer[1] != 'Z') {
        printf("Not MZ signature\n");
        free(buffer);
        return 1;
    }

    uint32_t pe_offset;
    memcpy(&pe_offset, &buffer[0x3C], 4);
    printf("PE signature offset: 0x%X\n", pe_offset);

    uint32_t coff_offset = pe_offset + 4;
    uint16_t Machine;
    uint16_t NumberOfSections;
    uint16_t SizeOfOptionalHeader;
    uint16_t Characteristics;

    memcpy(&Machine, &buffer[coff_offset], 2);
    memcpy(&NumberOfSections, &buffer[coff_offset + 2], 2);
    memcpy(&SizeOfOptionalHeader, &buffer[coff_offset + 16], 2);
    memcpy(&Characteristics, &buffer[coff_offset + 18], 2);

    printf("Machine: 0x%X\n", Machine);
    printf("NumberOfSections: %d\n", NumberOfSections);
    printf("SizeOfOptionalHeader: 0x%X\n", SizeOfOptionalHeader);
    printf("Characteristics: 0x%X\n", Characteristics);

    uint32_t opt_offset = coff_offset + 20;
    uint16_t magic;
    memcpy(&magic, &buffer[opt_offset], 2);
    printf("Optional Header Magic: 0x%X\n", magic);

    uint32_t entry_point;
    uint64_t image_base;
    uint32_t section_align;
    uint32_t file_align;
    uint32_t size_of_image;
    uint32_t size_of_headers;
    uint16_t subsystem;
    uint16_t dll_chars;

    memcpy(&entry_point, &buffer[opt_offset + 16], 4);
    memcpy(&image_base, &buffer[opt_offset + 24], 8);
    memcpy(&section_align, &buffer[opt_offset + 32], 4);
    memcpy(&file_align, &buffer[opt_offset + 36], 4);
    memcpy(&size_of_image, &buffer[opt_offset + 56], 4);
    memcpy(&size_of_headers, &buffer[opt_offset + 60], 4);
    memcpy(&subsystem, &buffer[opt_offset + 68], 2);
    memcpy(&dll_chars, &buffer[opt_offset + 70], 2);

    printf("AddressOfEntryPoint: 0x%X\n", entry_point);
    printf("ImageBase: 0x%llX\n", image_base);
    printf("SectionAlignment: 0x%X\n", section_align);
    printf("FileAlignment: 0x%X\n", file_align);
    printf("SizeOfImage: 0x%X\n", size_of_image);
    printf("SizeOfHeaders: 0x%X\n", size_of_headers);
    printf("Subsystem: %d\n", subsystem);
    printf("DllCharacteristics: 0x%X\n", dll_chars);

    // Read Import Directory Table RVA and size
    uint32_t import_table_rva;
    uint32_t import_table_size;
    memcpy(&import_table_rva, &buffer[opt_offset + 120], 4);
    memcpy(&import_table_size, &buffer[opt_offset + 124], 4);
    printf("Import Table RVA: 0x%X (Size: 0x%X)\n", import_table_rva, import_table_size);

    uint32_t sec_table_offset = opt_offset + SizeOfOptionalHeader;
    IMAGE_SECTION_HEADER* sections = malloc(NumberOfSections * sizeof(IMAGE_SECTION_HEADER));
    printf("\n--- SECTIONS ---\n");
    for (int s = 0; s < NumberOfSections; s++) {
        uint32_t off = sec_table_offset + s * sizeof(IMAGE_SECTION_HEADER);
        memcpy(&sections[s], &buffer[off], sizeof(IMAGE_SECTION_HEADER));
        
        char name_buf[9] = {0};
        memcpy(name_buf, sections[s].Name, 8);
        printf("Section %d: %s\n", s, name_buf);
        printf("  VirtualSize: 0x%X\n", sections[s].VirtualSize);
        printf("  VirtualAddress: 0x%X\n", sections[s].VirtualAddress);
        printf("  SizeOfRawData: 0x%X\n", sections[s].SizeOfRawData);
        printf("  PointerToRawData: 0x%X\n", sections[s].PointerToRawData);
        printf("  Characteristics: 0x%X\n", sections[s].Characteristics);
    }

    if (import_table_rva != 0 && import_table_size != 0) {
        uint32_t import_offset = rva_to_offset(import_table_rva, sections, NumberOfSections);
        printf("\n--- IMPORTS (offset: 0x%X) ---\n", import_offset);
        if (import_offset == 0) {
            printf("Could not map Import Table RVA to file offset!\n");
        } else {
            IMAGE_IMPORT_DESCRIPTOR* desc = (IMAGE_IMPORT_DESCRIPTOR*)&buffer[import_offset];
            while (desc->NameRVA != 0) {
                uint32_t name_offset = rva_to_offset(desc->NameRVA, sections, NumberOfSections);
                const char* dll_name = (name_offset != 0) ? (const char*)&buffer[name_offset] : "unknown";
                printf("DLL: %s\n", dll_name);
                printf("  ImportLookupTableRVA: 0x%X\n", desc->ImportLookupTableRVA);
                printf("  ImportAddressTableRVA: 0x%X\n", desc->ImportAddressTableRVA);

                // Print functions
                uint32_t lookup_rva = desc->ImportLookupTableRVA ? desc->ImportLookupTableRVA : desc->ImportAddressTableRVA;
                uint32_t lookup_offset = rva_to_offset(lookup_rva, sections, NumberOfSections);
                if (lookup_offset != 0) {
                    int f = 0;
                    while (1) {
                        uint64_t entry;
                        memcpy(&entry, &buffer[lookup_offset + f * 8], 8);
                        if (entry == 0) break;
                        
                        if (entry & (1ULL << 63)) {
                            // Import by ordinal
                            printf("    Ordinal: %llu\n", entry & 0xFFFF);
                        } else {
                            // Import by name
                            uint32_t name_entry_offset = rva_to_offset((uint32_t)entry, sections, NumberOfSections);
                            if (name_entry_offset != 0) {
                                uint16_t hint = buffer[name_entry_offset] | (buffer[name_entry_offset + 1] << 8);
                                const char* func_name = (const char*)&buffer[name_entry_offset + 2];
                                printf("    Function: %s (hint: %u)\n", func_name, hint);
                            } else {
                                printf("    Invalid name RVA: 0x%llX\n", entry);
                            }
                        }
                        f++;
                    }
                } else {
                    printf("  Could not resolve ILT/IAT offset!\n");
                }
                desc++;
            }
        }
    }

    free(sections);
    free(buffer);
    return 0;
}

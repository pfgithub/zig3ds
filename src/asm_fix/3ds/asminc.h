#pragma once

#if !__ASSEMBLER__
    #error This header file is only for use in assembly files!
#endif // !__ASSEMBLER__

.macro BEGIN_ASM_FUNC name, linkage=global, section=text
    .section        .\section\().\name, "ax", %progbits
    .align          2
    .\linkage       \name
    .type           \name, %function
#if defined(__GNUC__) && !defined(__llvm__)
    .func           \name
#endif
    .cfi_sections   .debug_frame
    .cfi_startproc
    \name:
.endm

.macro END_ASM_FUNC
    .cfi_endproc
#if defined(__GNUC__) && !defined(__llvm__)
    #error "GNUC"
    .endfunc
#endif
.endm

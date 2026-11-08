; A2Z module ABI: origin 0x4000, max 4096 bytes, preserve SP, RET, result in HL.
; Computes 1+2+...+100 = 5050 (0x13BA). No disk, serial or bank-switch access.
        org 0x04000
        ld hl,0
        ld de,1
        ld b,100
again:  add hl,de
        inc de
        djnz again
        ret

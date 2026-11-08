; Standalone CP/M program. Transfer HELLO.HEX with PIP, then LOAD HELLO.
        org 0x0100
        ld de,message
        ld c,9
        call 5
        jp 0
message: db 72,101,108,108,111,32,102,114,111,109,32,116,104,101,32,80,114,101,109,105,117,109,32,83,111,102,116,67,97,114,100,32,73,73,101,32,90,56,48,33,13,10,36

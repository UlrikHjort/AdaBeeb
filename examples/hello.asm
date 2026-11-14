; Hello world for the BBC Micro (ACME syntax) - F5 in the forge runs it
oswrch = $ffee          ; write a character
osnewl = $ffe7          ; new line

        *= $1900        ; PAGE with DFS
        !basic          ; 10 CALL &xxxx, so RUN starts the program

start   ldx #0
-       lda text,x
        beq +
        jsr oswrch
        inx
        bne -
+       jsr osnewl
        rts

text    !text 22, 7                 ; MODE 7
        !text 141, 132, 157, 131, "Hello from AdaBeeb", 13, 10
        !text 141, 132, 157, 131, "Hello from AdaBeeb", 0

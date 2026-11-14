; program used by debug_test (debugger API)
        *= $1900
        !basic
counter = $70
start   lda #0
        sta counter
main    jsr sub             ; step over this
after   inc counter
        lda counter
        sta $0900           ; watchpoint target
        cmp #3
        bne main
done    jmp done

sub     ldx #10
-       dex
        bne -
        jsr inner
back    rts

inner   nop
        rts

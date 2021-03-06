@ vim:noet:sw=8:ts=8:ai:syn=armasm

@ LPC1114 Synthesizer
@ Matt Sarnoff (msarnoff.org)
@ November 24, 2013
@
@ Sound generation kernel.
@ The SysTick handler is executed from RAM for super speed!
@ This function makes heavy (ab)use of self-modifying code;
@ many of the instructions are changed by the C code to vary parameters
@ without branching.
@ DO NOT MODIFY UNLESS YOU KNOW WHAT YOU DOING!!1
@ Changing/adding/removing instructions without changing the corresponding
@ constants in sound.c will probably cause the CPU to lock up.
.data
_SysTick_Handler:
	mov	r3, #0			@ sample accumulator
	adr	r0, osc0		@ point to first oscillator
silence:
	b	stop_oscillators	@ modifiable; becomes a nop when envelope != 0

osc_update_base:
@ Update all oscillators
@ Self-modifying code is used to change the waveform, volume, and duty cycle
.rept 4
	ldmia	r0, {r0, r1, r2}
	add	r2, r1
	stmia	r0!, {r2}
	mov	r1, #255		@ precompute the constant 0x1FE00000
	lsl	r1, #21			@ TODO: this is suboptimal
@ ----- begin modifiable code
	asr	r2, #23
	sub	r2, #0			@ subtract duty cycle to get a bitmask
	eor	r2, r1			@ leaves junk in the lower bits but it's too insignificant to matter
@ ----- end modifiable code
	add	r3, r2
.endr

@ When sawtooth wave is selected, the "modifiable code" sections
@ will be replaced with the following instructions:
@	asr	r2, #2
@	nop
@	nop

filter_bypass_control:
	nop				@ modifiable
@	b	filter_bypass

@ Chamberlin state-variable filter
@ L = D2 + F1*D1
@ H = I - L - Q1*D1
@ B = F1*H + D1
@ D1 = B
@ D2 = L
@ F1 is an unsigned 16.16 fixed point number limited to the range [0, 1]
@ Q1 is an unsigned 16.16 fixed point number limited to the range [0, 2]
@ L, H, B, D1, and D2 are signed 20.12 fixed-point numbers;
@   their range is limited to [-8, 8) to prevent overflow during multiplication
@ I (input) is a 28-bit binary fraction and must be adjusted
filter:
@ shift oscillator output down to 20.12 for input to filter
	asr	r3, #19
@ compute lowpass output
	ldmia	r0, {r0, r1, r2}	@ get D2, frequency, D1
	mul	r1, r2			@ D1*F1; 20.12 * 16.16
	asr	r1, #16			@ shift result back to 20.12
	add	r0, r1			@ r0 = L = D2 + D1*F1
	mov	r12, r0			@ save L
@ r12 now contains lowpass output
@ compute highpass output
	sub	r3, r0			@ r3 = H = I - L
	adr	r0, _filter_cutoff
	ldmia	r0, {r0, r1, r2}	@ get frequency, D1, Q
	mul	r2, r1			@ D1*Q1; 20.12 * 16.16
	asr	r2, #16			@ shift result back to 20.12
	sub	r3, r2			@ r3 = H = I - L - D1*Q1
@ r12 = lowpass output
@ r3  = highpass output
@ r0  = frequency
@ r1  = D1 
@ compute bandpass output
	mul	r0, r3			@ r0 = B = H*F1; 20.12 * 16.16
	asr	r0, #16			@ shift result back to 20.12
	add	r0, r1			@ r0 = B = H*F1 + D1
	mov	r1, r12			@ bring back lowpass output
@ r1 = lowpass output
@ r3  = highpass output
@ r0  = bandpass output
@ store the new delay values
	adr	r2, filter_d2
	str	r1, [r2, #0]		@ D2 = L
	str	r0, [r2, #8]		@ D1 = B
@ choose an output
filter_mode_control:
	mov	r3, r1			@ modifiable

@ Clip
	ldr	r0, clip_threshold
	cmp	r3, r0
	bgt	clip
	neg	r0, r0
	cmp	r3, r0
	blt	clip

apply_envelope:
volume_control:
	mov	r0, #255		@ modifiable
	add	r0, #1
	mul	r3, r0
	lsr	r3, #10

@ Send 12-bit sample in r3 to DAC
dacout:
	adr	r0, output_port
	ldmia	r0, {r0, r1, r2}
	add	r3, r1			@ convert 2's complement to offset
	orr	r3, r2			@ set /GA and /SHDN bits
	strh	r3, [r0]		@ send to DAC
	bx	lr

filter_bypass:
	asr	r3, #18			@ shift down to 12 bits for DAC
	b	apply_envelope

clip:
	mov	r3, r0
	b	apply_envelope

stop_oscillators:
	str	r3, [r0, #osc0ph-osc0]	@ zero out all phase accumulators
	str	r3, [r0, #osc1ph-osc0]
	str	r3, [r0, #osc2ph-osc0]
	str	r3, [r0, #osc3ph-osc0]
	str	r3, [r0, #filter_d2-osc0]
	str	r3, [r0, #filter_d1-osc0]
	b	dacout
	

.align 4
@ oscillator states
@ 3 words per oscillator (phase pointer, frequency, phase)
@ the phase pointer allows r0 to point to the phase word after an ldm
oscillators:
osc0:	.word	osc0ph
osc0fr:	.word	0
osc0ph:	.word	0
osc1:	.word	osc1ph
osc1fr:	.word	0
osc1ph:	.word	0
osc2:	.word	osc2ph
osc2fr:	.word	0
osc2ph:	.word	0
osc3:	.word	osc3ph
osc3fr:	.word	0
osc3ph:	.word	0

@ filter state and parameters
filter_d2:
	.word	0
_filter_cutoff:
	.word	0xffff			@ 16.16 unsigned fixed point, in the range [0, 1]
filter_d1:
	.word	0
filter_q:
	.word	0x10000			@ 16.16 unsigned fixed point, in the range [0, 2)
clip_threshold:
	.word	0x1fff

@ constants used for DAC output
output_port:
	.word	0x40040008		@ SPI data register
offset:
	.word	0x00000800		@ convert 2's complement to offset
dac_bits:
	.word	0x00003000		@ /GA and /SHDN bits

.global oscillators
.global osc_update_base
.global filter_cutoff
.global filter_q
.global filter_mode_control
.global filter_bypass_control
.global volume_control
.global silence
.set filter_cutoff, _filter_cutoff

@ make sure the thumb bit is set in the vector table
.global SysTick_Handler
.thumb_set SysTick_Handler, _SysTick_Handler

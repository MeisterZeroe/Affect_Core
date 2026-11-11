<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The Echoes Affect Core is the emotional "brainstem" of Echoes, a companion robot by Evil Company Ink. It is a
hardware port of the emotion module from CIPHER, the Python platform that runs Echoes.

The chip holds one mood out of twelve (neutral, engaged, curious, amused, irritated, frustrated, resigned,
concerned, hurt, angry, satisfied, melancholy) and an 8-bit intensity. A Raspberry Pi sends each user message
as a "turn": a byte of detector flags (hostile, insult, success, compliment, interesting, question, joke,
distress) plus a repeat count. The chip applies a fixed priority list of transition rules to pick the next
mood and intensity, the same rules the Python version uses.

Over time, intensity decays back toward neutral, and a long silence can make Echoes melancholy. Four reflex
inputs (loud noise, touch, motion, tilt) change her mood directly without the Pi. A small LFSR decides
whether an insult leaves her hurt or angry.

The current mood is always visible on four output pins, and intensity is available as a PWM signal, so a
face board or LEDs can show her mood even when the Pi is offline.

## How to test

Connect an SPI master (mode 0, 1 MHz or slower) to ui[0] SCK, ui[1] MOSI, ui[2] CS_N and uo[0] MISO, and run
the design at 10 MHz. Each transaction is 16 bits: the first byte is a read flag (bit 7) plus a 7-bit
address, the second byte is write data or the returned read data.

1. Read register 0x00. It returns 0xEC.
2. Read registers 0x02 (mood) and 0x03 (intensity). After reset they are 0 (neutral) and 77.
3. Write 1 to register 0x08 (repeat count), then 0x01 to register 0x09 (turn flags: hostile).
4. Read 0x02 and 0x03 again. They are now 9 (angry) and 242, and uo[5:2] shows 9.
5. Write 0x04 to register 0x0F to reset to neutral.

Pulsing ui[7] (tilt) high while she is calm makes her hurt or angry, the same as an insult.

## External hardware

A Raspberry Pi (or any SPI master) to send turns and read the mood. Optional: a microphone loudness
comparator, a touch pad, a motion sensor and a tilt switch on the reflex inputs; LEDs on the mood and PWM
outputs.

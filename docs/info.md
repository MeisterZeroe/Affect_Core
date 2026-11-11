<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

The Affect Core is a faithful hardware port of CIPHER's EchoesEmotionalState (Emotion.py): one mood out of 12, one intensity from 0.1 to 1.0, and the same priority rules, now running in silicon in Echoes's torso. It also gives the four moods Emotion.py describes but never reaches (curious, amused, concerned, melancholy) their own triggers, and adds time-based cooling.

## How to test

Goals:
•	Same Echoes. Every existing rule carries over with the same priorities and the same numbers, converted to 8-bit integers.
•	All 12 moods live. New, clearly marked rules reach the four unused moods without changing how the existing eight behave.
•	Feel without software. Mood and intensity live on the chip, keep cooling over time, and survive Pi reboots and Wi-Fi drops.
•	Fully offline. No network, firmware, or update path; the only ways in are SPI and four reflex wires.
•	Fits a hobby shuttle. One Tiny Tapeout tile on SKY130.


## External hardware

List external hardware used in your project (e.g. PMOD, LED display, etc), if any

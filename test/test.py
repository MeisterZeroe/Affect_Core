# SPDX-FileCopyrightText: 2026 Evil Company Ink. LLC
# SPDX-License-Identifier: Apache-2.0
#
# cocotb test for the Echoes Affect Core (tt_um_eci_affect_core).
# Talks to the chip only through its pins, so it runs for both the RTL
# test and the gate-level test in the Tiny Tapeout GitHub Actions.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# Mood codes (order of the MOODS dict in Emotion.py)
(NEUTRAL, ENGAGED, CURIOUS, AMUSED, IRRITATED, FRUSTRATED,
 RESIGNED, CONCERNED, HURT, ANGRY, SATISFIED, MELANCHOLY) = range(12)

# Turn flags
HOSTILE, INSULT, SUCCESS, COMPLIMENT = 0x01, 0x02, 0x04, 0x08
INTERESTING, QUESTION, JOKE, DISTRESS = 0x10, 0x20, 0x40, 0x80

# Registers
R_ID, R_VERSION, R_MOOD, R_INTENSITY, R_STATUS = 0x00, 0x01, 0x02, 0x03, 0x04
R_REPEAT, R_TURN, R_EVENT = 0x08, 0x09, 0x0A
R_TICK_DIV, R_COOL, R_MEL_DELAY, R_ODDS, R_CONTROL = 0x0B, 0x0C, 0x0D, 0x0E, 0x0F

# Events and reflex wires
GOODBYE = 0
LOUD, TOUCH, MOTION, TILT = 0, 1, 2, 3

HALF = 5  # system clocks per half SCK period: 1 MHz SCK at a 10 MHz clock


class Pins:
    """Keeps the ui_in bits together so SPI and reflex drives don't clobber each other."""

    def __init__(self, dut):
        self.dut = dut
        self.sck = 0
        self.mosi = 0
        self.csn = 1
        self.test_mode = 0
        self.reflex = 0

    def drive(self):
        self.dut.ui_in.value = ((self.reflex << 4) | (self.test_mode << 3) |
                                (self.csn << 2) | (self.mosi << 1) | self.sck)


async def xfer(p, b0, b1):
    """One 16-bit SPI mode 0 transaction. Returns the byte clocked in during byte 1."""
    word = (b0 << 8) | b1
    rx = 0
    p.csn = 0
    p.drive()
    await ClockCycles(p.dut.clk, HALF)
    for n in range(15, -1, -1):
        p.mosi = (word >> n) & 1
        p.drive()
        await ClockCycles(p.dut.clk, HALF)
        if n < 8:
            rx = (rx << 1) | (int(p.dut.uo_out.value) & 1)   # sample MISO at the rising edge
        p.sck = 1
        p.drive()
        await ClockCycles(p.dut.clk, HALF)
        p.sck = 0
        p.drive()
    await ClockCycles(p.dut.clk, HALF)
    p.csn = 1
    p.drive()
    await ClockCycles(p.dut.clk, 10)
    return rx


async def wr(p, addr, data):
    await xfer(p, addr & 0x7F, data & 0xFF)


async def rd(p, addr):
    return await xfer(p, 0x80 | addr, 0x00)


async def turn(p, rep, flags):
    await wr(p, R_REPEAT, rep)
    await wr(p, R_TURN, flags)


async def pulse_reflex(p, line):
    p.reflex |= (1 << line)
    p.drive()
    await ClockCycles(p.dut.clk, 20)
    p.reflex &= ~(1 << line)
    p.drive()
    await ClockCycles(p.dut.clk, 20)


async def expect_state(p, mood, intensity, what):
    m = await rd(p, R_MOOD)
    i = await rd(p, R_INTENSITY)
    pins = (int(p.dut.uo_out.value) >> 2) & 0xF
    assert (m, i, pins) == (mood, intensity, mood), \
        f"{what}: got mood {m} (pins {pins}), intensity {i}; expected mood {mood}, intensity {intensity}"
    p.dut._log.info(f"PASS  {what}  (mood {m}, intensity {i})")


async def expect_reg(p, addr, value, what):
    v = await rd(p, addr)
    assert v == value, f"{what}: register 0x{addr:02X} = 0x{v:02X}, expected 0x{value:02X}"
    p.dut._log.info(f"PASS  {what}  (0x{addr:02X} = 0x{v:02X})")


@cocotb.test()
async def test_affect_core(dut):
    dut._log.info("Start")

    cocotb.start_soon(Clock(dut.clk, 100, "ns").start())   # 10 MHz

    p = Pins(dut)
    dut.ena.value = 1
    dut.uio_in.value = 0
    p.drive()
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)

    # Identity and reset state
    await expect_reg(p, R_ID, 0xEC, "ID reads 0xEC")
    await expect_reg(p, R_VERSION, 0x02, "VERSION reads 0x02")
    await expect_state(p, NEUTRAL, 77, "reset: neutral at 0.3")

    # Exact Emotion.py mode: no time rules
    await wr(p, R_COOL, 0)
    await wr(p, R_MEL_DELAY, 0)

    # Rules 1 and 2
    await turn(p, 1, HOSTILE)
    await expect_state(p, ANGRY, 242, "hostile -> angry 0.95")
    await turn(p, 1, INSULT)
    await expect_state(p, ANGRY, 255, "insult while angry -> I+0.3, clamped")

    await wr(p, R_CONTROL, 0x04)
    await expect_state(p, NEUTRAL, 77, "CONTROL.RESET -> neutral 0.3")

    # Rule 4: repetition ladder
    await turn(p, 2, 0)
    await expect_state(p, IRRITATED, 89, "2nd repeat while neutral -> irritated 0.35")
    await turn(p, 3, 0)
    await expect_state(p, FRUSTRATED, 153, "3rd repeat while irritated -> frustrated I+0.25")
    await turn(p, 5, 0)
    await expect_state(p, RESIGNED, 217, "5th repeat -> resigned 0.85")

    # Rule 10: per-turn decay
    await turn(p, 1, 0)
    await expect_state(p, RESIGNED, 199, "plain turn -> decay 0.07")
    for _ in range(9):
        await turn(p, 1, 0)
    await expect_state(p, NEUTRAL, 77, "decay below 0.15 -> neutral 0.3")

    # Rules 6 and 7; engaged never decays
    await turn(p, 1, COMPLIMENT)
    await expect_state(p, ENGAGED, 140, "compliment while neutral -> engaged 0.55")
    await turn(p, 1, 0)
    await expect_state(p, ENGAGED, 140, "engaged does not decay")
    await turn(p, 1, INTERESTING)
    await expect_state(p, ENGAGED, 166, "interesting while engaged -> I+0.1")

    # New rules 8 and 9
    await turn(p, 1, JOKE)
    await expect_state(p, AMUSED, 153, "joke while engaged -> amused (new)")
    await turn(p, 1, QUESTION)
    await expect_state(p, CURIOUS, 140, "question while amused -> curious (new)")

    # Rule 5 and new rule 3
    await turn(p, 1, SUCCESS)
    await expect_state(p, SATISFIED, 179, "success -> satisfied 0.7")
    await turn(p, 1, DISTRESS)
    await expect_state(p, CONCERNED, 179, "distress -> concerned (new)")

    # Rule 2 with the coin flip forced to angry
    await wr(p, R_ODDS, 0)
    await turn(p, 1, INSULT)
    await expect_state(p, ANGRY, 191, "insult while calm, odds 0 -> angry 0.75")
    await wr(p, R_ODDS, 154)

    # Rule 6 from a bad mood
    await turn(p, 1, COMPLIMENT)
    await expect_state(p, NEUTRAL, 102, "compliment while angry -> neutral 0.4")

    # Events (new)
    await wr(p, R_EVENT, GOODBYE)
    await expect_state(p, NEUTRAL, 102, "goodbye while neutral -> no change")
    await turn(p, 1, COMPLIMENT)
    await wr(p, R_EVENT, GOODBYE)
    await expect_state(p, MELANCHOLY, 89, "goodbye while engaged -> melancholy (new)")
    await pulse_reflex(p, TOUCH)
    await expect_state(p, NEUTRAL, 77, "touch wire while melancholy -> neutral (new)")
    await pulse_reflex(p, LOUD)
    await expect_state(p, CURIOUS, 115, "loud wire while neutral -> curious (new)")
    await wr(p, R_ODDS, 0)
    await pulse_reflex(p, TILT)
    await expect_state(p, ANGRY, 191, "tilt wire -> knocked -> insult rule (new)")
    await wr(p, R_ODDS, 154)

    # Time cooling (new), with fast ticks for simulation
    await wr(p, R_TICK_DIV, 4)     # one tick every 16 clocks
    await wr(p, R_COOL, 2)         # one decay step every 2 ticks
    await ClockCycles(dut.clk, 1000)
    await expect_state(p, NEUTRAL, 77, "time cooling: angry -> neutral alone (new)")

    # Melancholy drift (new)
    await wr(p, R_COOL, 0)
    await rd(p, R_STATUS)          # reading STATUS clears CHANGED and the turn counter
    await wr(p, R_MEL_DELAY, 1)    # after 16 ticks of silence
    await ClockCycles(dut.clk, 600)
    await expect_state(p, MELANCHOLY, 102, "long silence while neutral -> melancholy (new)")
    await expect_reg(p, R_STATUS, 0x06, "STATUS: MELANCHOLY_FIRED and CHANGED set")
    await wr(p, R_COOL, 1)
    await ClockCycles(dut.clk, 600)
    await expect_state(p, MELANCHOLY, 102, "cooling skips melancholy (new)")
    await turn(p, 1, 0)
    await expect_state(p, MELANCHOLY, 84, "plain turn still decays melancholy")

    # Lock
    await wr(p, R_CONTROL, 0x01)
    await wr(p, R_INTENSITY, 200)
    await expect_state(p, MELANCHOLY, 84, "LOCK: intensity write ignored")
    status = await rd(p, R_STATUS)
    assert status & 0x01, f"STATUS.LOCKED not set (0x{status:02X})"
    dut._log.info("PASS  STATUS.LOCKED set")

    # Debug bus
    p.test_mode = 1
    p.drive()
    await ClockCycles(dut.clk, 2)
    assert int(dut.uio_oe.value) == 0xFF and int(dut.uio_out.value) == MELANCHOLY, \
        f"debug bus: oe 0x{int(dut.uio_oe.value):02X}, out {int(dut.uio_out.value)}"
    dut._log.info("PASS  debug bus shows MOOD in test mode")

    dut._log.info("All checks passed")

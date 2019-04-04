// Copyright (c) 2012-2013 Ludvig Strigeus
// This program is GPL Licensed. See COPYING for the full license.

//`include "cpu.v"
//`include "apu.v"
//`include "ppu.v"
//`include "mmu.v"

// Sprite DMA Works as follows.
// When the CPU writes to $4014 DMA is initiated ASAP.
// DMA runs for 512 cycles, the first cycle it reads from address
// xx00 - xxFF, into a latch, and the second cycle it writes to $2004.

// Facts:
// 1) Sprite DMA always does reads on even cycles and writes on odd cycles.
// 2) There are 1-2 cycles of cpu_read=1 after cpu_read=0 until Sprite DMA starts (pause_cpu=1, aout_enable=0)
// 3) Sprite DMA reads the address value on the last clock of cpu_read=0

/*

=== DMC State Machine ===

// 
if (dmc_state == 0 && dmc_trigger && cpu_read && !odd_cycle) dmc_state <= 1;
if (dmc_state == 1) dmc_state <= (spr_state[1] ? 3 : 2);
pause_cpu = dmc_state[1] && cpu_read;
if (dmc_state == 2 && cpu_read && !odd_cycle) dmc_state <= 3;
aout_enable = (dmc_state == 3 && !odd_cycle)
dmc_ack     = (dmc_state == 3 && !odd_cycle)
read        = 1
if (dmc_state == 3 && !odd_cycle) dmc_state <= 0;

== Sprite State Machine ==
if (sprite_trigger) { sprite_dma_addr <= data_from_cpu; spr_state <= 1; }
pause_cpu = spr_state[0] && cpu_read;
if (spr_state == 1 && cpu_read && odd_cycle) spr_state <= 3;
if (spr_state == 3 && !odd_cycle) { if (dmc_state == 3) spr_state <= 1; else DO_READ; }
if (spr_state == 3 && odd_cycle) { DO_WRITE; }


// 4) If DMC interrupts Sprite, then it runs on the even cycle, and the odd cycle will be idle (pause_cpu=1, aout_enable=0)
// 5) When DMC triggers && interrupts CPU, there will be 2-3 cycles (pause_cpu=1, aout_enable=0) before DMC DMA starts.
*/


module DmaController(input clk, input ce, input reset,
                     input odd_cycle,               // Current cycle even or odd?
                     input sprite_trigger,          // Sprite DMA trigger?
                     input dmc_trigger,             // DMC DMA trigger?
                     input cpu_read,                // CPU is in a read cycle?
                     input [7:0] data_from_cpu,     // Data written by CPU?
                     input [7:0] data_from_ram,     // Data read from RAM?
                     input [15:0] dmc_dma_addr,     // DMC DMA Address
                     output [15:0] aout,            // Address to access
                     output aout_enable,            // DMA controller wants bus control
                     output read,                   // 1 = read, 0 = write
                     output [7:0] data_to_ram,      // Value to write to RAM
                     output dmc_ack,                // ACK the DMC DMA
                     output pause_cpu);             // CPU is paused
  reg dmc_state;
  reg [1:0] spr_state;
  reg [7:0] sprite_dma_lastval;
  reg [15:0] sprite_dma_addr;     // sprite dma source addr
  wire [8:0] new_sprite_dma_addr = sprite_dma_addr[7:0] + 8'h01;
  always @(posedge clk) if (reset) begin
    dmc_state <= 0;
    spr_state <= 0;    
    sprite_dma_lastval <= 0;
    sprite_dma_addr <= 0;
  end else if (ce) begin
    if (dmc_state == 0 && dmc_trigger && cpu_read && !odd_cycle) dmc_state <= 1;
    if (dmc_state == 1 && !odd_cycle) dmc_state <= 0;
    
    if (sprite_trigger) begin sprite_dma_addr <= {data_from_cpu, 8'h00}; spr_state <= 1; end
    if (spr_state == 1 && cpu_read && odd_cycle) spr_state <= 3;
    if (spr_state[1] && !odd_cycle && dmc_state == 1) spr_state <= 1;
    if (spr_state[1] && odd_cycle) sprite_dma_addr[7:0] <= new_sprite_dma_addr[7:0];
    if (spr_state[1] && odd_cycle && new_sprite_dma_addr[8]) spr_state <= 0;
    if (spr_state[1]) sprite_dma_lastval <= data_from_ram;
  end
  assign pause_cpu = (spr_state[0] || dmc_trigger) && cpu_read;
  assign dmc_ack   = (dmc_state == 1 && !odd_cycle);
  assign aout_enable = dmc_ack || spr_state[1];
  assign read = !odd_cycle;
  assign data_to_ram = sprite_dma_lastval;
  assign aout = dmc_ack ? dmc_dma_addr : !odd_cycle ? sprite_dma_addr : 16'h2004;
endmodule

// Multiplexes accesses by the PPU and the PRG into a single memory, used for both
// ROM and internal memory.
// PPU has priority, its read/write will be honored asap, while the CPU's reads
// will happen only every second cycle when the PPU is idle.
// Data read by PPU will be available on the next clock cycle.
// Data read by CPU will be available within at most 2 clock cycles.

module MemoryMultiplex(input clk, input ce, input reset,
                       input [21:0] prg_addr, input prg_read, input prg_write, input [7:0] prg_din,
                       input [21:0] chr_addr, input chr_read, input chr_write, input [7:0] chr_din,
                       // Access signals for the SRAM.
                       output [21:0] memory_addr,   // address to access
                       output memory_read_cpu,      // read into CPU latch
                       output memory_read_ppu,      // read into PPU latch
                       output memory_write,         // is a write operation
                       output [7:0] memory_dout);
  reg saved_prg_read, saved_prg_write;
  assign memory_addr = (chr_read || chr_write) ? chr_addr : prg_addr;
  assign memory_write = (chr_read || chr_write) ? chr_write : saved_prg_write;
  assign memory_read_ppu = chr_read;
  assign memory_read_cpu = !(chr_read || chr_write) && (prg_read || saved_prg_read);
  assign memory_dout = chr_write ? chr_din : prg_din;
  always @(posedge clk) if (reset) begin
		saved_prg_read <= 0;
		saved_prg_write <= 0;
  end else if (ce) begin
    if (chr_read || chr_write) begin
      saved_prg_read <= prg_read || saved_prg_read;
      saved_prg_write <= prg_write || saved_prg_write;
    end else begin
      saved_prg_read <= 0;
      saved_prg_write <= prg_write;
    end
  end
endmodule


module NES(input clk, input reset, input ce,
           input [31:0] mapper_flags,
           output [15:0] sample, // sample generated from APU
           output [5:0] color,  // pixel generated from PPU
           output joypad_strobe,// Set to 1 to strobe joypads. Then set to zero to keep the value.
           output [1:0] joypad_clock, // Set to 1 for each joypad to clock it.
           input [3:0] joypad_data, // Data for each joypad + 1 powerpad.
           input mic,               // Microphone RNG
           input fds_swap,
           input [4:0] audio_channels, // Enabled audio channels

           // Access signals for the SRAM.
           output [21:0] memory_addr,   // address to access
           output memory_read_cpu,      // read into CPU latch
           input [7:0] memory_din_cpu,  // next cycle, contents of latch A (CPU's data)
           output memory_read_ppu,      // read into CPU latch
           input [7:0] memory_din_ppu,  // next cycle, contents of latch B (PPU's data)
           output memory_write,         // is a write operation
           output [7:0] memory_dout,
			  // Override for BRAM
           output [14:0] bram_addr,     // address to access
           input [7:0] bram_din,        // Data from BRAM
           output [7:0] bram_dout,
           output bram_write,           // is a write operation
           output bram_override,
           
           output [8:0] cycle,
           output [8:0] scanline,
           input int_audio,
           input ext_audio
           );
  reg [7:0] from_data_bus;
  wire [7:0] cpu_dout;
  wire odd_or_even; // Is this an odd or even clock cycle?

  // The CPU runs at one third the speed of the PPU.
  // CPU is clocked at cycle #2. PPU is clocked at cycle #0, #1, #2.
  // CPU does its memory I/O on cycle #0. It will be available in time for cycle #2.
  reg [1:0] cpu_cycle_counter;
  always @(posedge clk) begin
    if (reset)
      cpu_cycle_counter <= 0;
    else if (ce)
      cpu_cycle_counter <= (cpu_cycle_counter == 2) ? 2'd0 : cpu_cycle_counter + 1'd1;
  end

  // Sample the NMI flag on cycle #0, otherwise if NMI happens on cycle #0 or #1,
  // the CPU will use it even though it shouldn't be used until the next CPU cycle.
  wire nmi;
  reg nmi_active;
  always @(posedge clk) begin
    if (reset)
      nmi_active <= 0;
    else if (ce && cpu_cycle_counter == 0)
      nmi_active <= nmi;
  end

  wire apu_ce = ce && (cpu_cycle_counter == 2);

  // -- CPU
  wire [15:0] cpu_addr;
  wire cpu_rnw;
  wire pause_cpu;
  reg apu_irq_delayed;
  reg mapper_irq_delayed;
  
	T65 cpu
	(
		.mode(0),
		.BCD_en(0),

		.res_n(~reset),
		.clk(clk),
		.enable(apu_ce && !pause_cpu),

		.IRQ_n(~(apu_irq_delayed | mapper_irq_delayed)),
		.NMI_n(~nmi_active),
		.R_W_n(cpu_rnw),

		.A(cpu_addr),
		.DI(cpu_rnw ? from_data_bus : cpu_dout),
		.DO(cpu_dout)
	);


  // -- DMA
  wire [15:0] dma_aout;
  wire dma_aout_enable;
  wire dma_read;
  wire [7:0] dma_data_to_ram;
  wire apu_dma_request, apu_dma_ack;
  wire [15:0] apu_dma_addr;

  // Determine the values on the bus outgoing from the CPU chip (after DMA / APU)
  wire [15:0] addr = dma_aout_enable ? dma_aout : cpu_addr;
  wire [7:0]  dbus = dma_aout_enable ? dma_data_to_ram : cpu_dout;
  wire mr_int      = dma_aout_enable ? dma_read : cpu_rnw;
  wire mw_int      = dma_aout_enable ? !dma_read : !cpu_rnw;

  DmaController dma(clk, apu_ce, reset, 
                    odd_or_even,                    // Even or odd cycle
                    (addr == 'h4014 && mw_int),     // Sprite trigger
                    apu_dma_request,                // DMC Trigger
                    cpu_rnw,                        // CPU in a read cycle?
                    cpu_dout,                       // Data from cpu
                    from_data_bus,                  // Data from RAM etc.
                    apu_dma_addr,                   // DMC addr
                    dma_aout,
                    dma_aout_enable, 
                    dma_read,
                    dma_data_to_ram,
                    apu_dma_ack,
                    pause_cpu);

  // -- Audio Processing Unit  
  wire apu_cs = addr >= 'h4000 && addr < 'h4018;
  wire [7:0] apu_dout;
  wire apu_irq;
  wire [15:0] sample_apu;
  APU apu(0, clk, apu_ce, reset,
          addr[4:0], dbus, apu_dout, 
          mw_int && apu_cs, mr_int && apu_cs,
          audio_channels,
          sample_apu,
          apu_dma_request,
          apu_dma_ack,
          apu_dma_addr,
          from_data_bus,
          odd_or_even,
          apu_irq);

  // Joypads are mapped into the APU's range.
  wire joypad1_cs = (addr == 'h4016);
  wire joypad2_cs = (addr == 'h4017);
  assign joypad_strobe = (joypad1_cs && mw_int && cpu_dout[0]);
  assign joypad_clock =  {joypad2_cs && mr_int, joypad1_cs && mr_int};

      
  // -- PPU
  // PPU _reads_ need to happen on the same cycle the cpu runs on, to guarantee we
  // see proper values of register $2002.
  wire mr_ppu     = mr_int && (cpu_cycle_counter == 2);
  wire mw_ppu     = mw_int && (cpu_cycle_counter == 0);
  wire ppu_cs = addr >= 'h2000 && addr < 'h4000;
  wire [7:0] ppu_dout;           // Data from PPU to CPU
  wire chr_read, chr_write;      // If PPU reads/writes from VRAM
  wire [13:0] chr_addr;          // Address PPU accesses in VRAM
  wire [7:0] chr_from_ppu;       // Data from PPU to VRAM
  wire [7:0] chr_to_ppu;
  wire [19:0] mapper_ppu_flags;  // PPU flags for mapper cheating
  PPU ppu(clk, ce, reset, color, dbus, ppu_dout, addr[2:0],
          ppu_cs && mr_ppu, ppu_cs && mw_ppu,
          nmi,
          chr_read, chr_write, chr_addr, chr_to_ppu, chr_from_ppu,
          scanline, cycle, mapper_ppu_flags);

  // -- Memory mapping logic
  wire [15:0] prg_addr = addr;
  wire [7:0] prg_din = dbus & (prg_conflict ? memory_din_cpu : 8'hFF);
  wire prg_read = mr_int && (cpu_cycle_counter == 0) && !apu_cs && !ppu_cs;
  wire prg_write = mw_int && (cpu_cycle_counter == 0) && !apu_cs && !ppu_cs;
  wire prg_allow, prg_open_bus, prg_conflict, vram_a10, vram_ce, chr_allow;
  wire [21:0] prg_linaddr, chr_linaddr;
  wire [7:0] prg_dout_mapper, chr_from_ppu_mapper;
  wire cart_ce = (cpu_cycle_counter == 0) && ce;
  wire mapper_irq;
  wire has_chr_from_ppu_mapper;
  wire [15:0] sample_ext;
  reg [16:0] sample_sum;
  assign sample = sample_sum[16:1]; //loss of 1 bit of resolution.  Add control for when no external audio to boost back up?
  
  cart_top multi_mapper (
    // FPGA specific
    .clk               (clk),
    .reset             (reset),
    .flags             (mapper_flags),            // iNES header data (use 0 while loading)
    // Cart pins (slightly abstracted)
    .ce                (cart_ce),        // M2 (held in high impedance during reset)
    .prg_ain           (prg_addr),                // CPU Address in (a15 abstracted from ROMSEL)
    .prg_read          (prg_read),                // CPU RnW split
    .prg_write         (prg_write),               // CPU RnW split
    .prg_din           (prg_din),                 // CPU Data bus in (split from bid)
    .prg_dout          (prg_dout_mapper),         // CPU Data bus out (split from bid)
    .chr_ain           (chr_addr),                // PPU address in
    .chr_read          (chr_read),                // PPU read (inverted, active high)
    .chr_write         (chr_write),               // PPU write (inverted, active high)
    .chr_din           (chr_from_ppu),            // PPU data bus in (split from bid)
    .chr_dout          (chr_from_ppu_mapper),     // PPU data bus in (split from bid)
    .vram_a10          (vram_a10),                // CIRAM a10 line
    .vram_ce           (vram_ce),                 // CIRAM chip enable
    .irq               (mapper_irq),              // IRQ (inverted, active high)
    .audio_in          (16'h0),                   // Amplified and inverted APU audio
    .audio             (sample_ext),              // Mixed audio output from cart
    // SDRAM Communication
    .prg_aout          (prg_linaddr),             // SDRAM adjusted PRG RAM address
    .prg_allow         (prg_allow),               // Simulates internal CE/Locking
    .chr_aout          (chr_linaddr),             // SDRAM adjusted CHR RAM address
    .chr_allow         (chr_allow),               // Simulates internal CE/Locking
    // External hardware interface (EEPROM)
    .mapper_addr       (bram_addr),
    .mapper_data_in    (bram_din),
    .mapper_data_out   (bram_dout),
    .mapper_prg_write  (bram_write),
    .mapper_ovr        (bram_override),
    // Cheats
    .prg_from_ram      (from_data_bus),           // Hacky cpu din <= get rid of this!
    .ppuflags          (mapper_ppu_flags),        // Cheat for MMC5
    .ppu_ce            (ce),                      // PPU Clock (cheat for MMC5/2/4)
    // Behavior helper flags
    .has_chr_dout      (has_chr_from_ppu_mapper), // Output specific data for CHR rather than from SDRAM
    .prg_open_bus      (prg_open_bus),            // Simulate open bus
    .prg_conflict      (prg_conflict),            // Simulate bus conflicts
    // User input
    .fds_swap          (fds_swap)                 // Used to trigger FDS disk changes
  );

  assign chr_to_ppu = has_chr_from_ppu_mapper ? chr_from_ppu_mapper : memory_din_ppu;
                             
  // Mapper IRQ seems to be delayed by one PPU clock.   
  // APU IRQ seems delayed by one APU clock.
  always @(posedge clk) if (reset) begin
    mapper_irq_delayed <= 0;
    apu_irq_delayed <= 0;
  end else begin
    if (ce)
      mapper_irq_delayed <= mapper_irq;
    if (apu_ce)
      apu_irq_delayed <= apu_irq;
    if (ce | apu_ce) begin
      case ({int_audio, ext_audio})
      0: sample_sum <= 17'b0;
      1: sample_sum <= {1'b0,sample_ext};
      2: sample_sum <= {1'b0,sample_apu};
      3: sample_sum <= {1'b0,sample_ext} + {1'b0,sample_apu};
      endcase
    end
  end
   
  // -- Multiplexes CPU and PPU accesses into one single RAM
  MemoryMultiplex mem(clk, ce, reset, prg_linaddr, (prg_read && prg_allow) | (prg_write && prg_conflict), prg_write && prg_allow, prg_din, 
                               chr_linaddr, chr_read, chr_write && (chr_allow || vram_ce), chr_from_ppu,
                               memory_addr, memory_read_cpu, memory_read_ppu, memory_write, memory_dout);

  reg [7:0] open_bus_data;
  always @(posedge clk) begin
      open_bus_data <= from_data_bus;
  end
  
  always @* begin
    if (reset)
      from_data_bus = 0;
    else if (apu_cs) begin
      if (joypad1_cs)
        from_data_bus = {5'b01000, mic, 1'b0, joypad_data[0]};
      else if (joypad2_cs)
        from_data_bus = {3'b010, joypad_data[3:2], 2'b00, joypad_data[1]};
      else
        from_data_bus = apu_dout;
    end else if (ppu_cs) begin
      from_data_bus = ppu_dout;
    end else if (prg_allow) begin
      from_data_bus = memory_din_cpu;
    end else if (prg_open_bus) begin
      from_data_bus = open_bus_data;
    end else begin
      from_data_bus = prg_dout_mapper;
    end
  end
  
endmodule

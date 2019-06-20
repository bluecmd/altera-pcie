//
// Copyright (C) 2014, 2017, 2019 Chris McClelland
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright  notice and this permission notice  shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
`timescale 1 ps / 1 ps

module altpcietb_bfm_driver_chaining#(
    parameter int TEST_LEVEL            = 1,       // Currently unused
    parameter bit USE_CDMA              = 1,       // When set enable EP upstream MRd/MWr test
    parameter bit USE_TARGET            = 1,       // When set enable target test
    parameter bit TL_BFM_MODE           = 1'b0,    // 0 means full stack RP BFM mode, 1 means TL-only RP BFM (remove CFG accesses to RP internal cfg space)
    parameter int TL_BFM_RP_CAP_REG     = 32'h42,  // In TL BFM mode, pass PCIE Capabilities reg thru parameter (- there is no RP config space). {specify:  port type, cap version}
    parameter int TL_BFM_RP_DEV_CAP_REG = 32'h05,  // In TL BFM mode, pass Device Capabilities reg thru parameter (- there is no RP config space). {specify:  maxpayld size}
    parameter int NUM_ITERATIONS        = 16
  )(
    input logic clk_in,
    input logic INTA,
    input logic INTB,
    input logic INTC,
    input logic INTD,
    input logic rstn,
    output logic dummy_out
  );

  // Include BFM utils
  `include "altpcietb_bfm_constants.v"
  `include "altpcietb_bfm_log.v"
  `include "altpcietb_bfm_shmem.v"
  `include "altpcietb_bfm_rdwr.v"
  `include "altpcietb_bfm_configure.v"

  // Import types, etc
  import tlp_xcvr_pkg::*;

  // Regions of host memory
  localparam int F2C_BASE_ADDR = 0;                         // this is used for the FPGA->CPU DMA buffer
  localparam int MTR_BASE_ADDR = F2C_BASE_ADDR + F2C_SIZE;  // this is used for the metrics buffer (e.g read & write pointers)
  localparam int TMP_BASE_ADDR = MTR_BASE_ADDR + MTR_SIZE;  // this is used for temporary buffer space (e.g for block writes to FPGA regions)
  localparam int F2C_WRPTR_ADDR = MTR_BASE_ADDR + 0;
  localparam int C2F_RDPTR_ADDR = MTR_BASE_ADDR + 4;

  // Success or failure
  typedef enum logic {
    SUCCESS = 1,
    FAILURE = 0
  } Result;

  task displayBarConfigs();
    int log2Size;
    bit isMem;
    bit isPref;
    bit is64b;
    $display("\nINFO: %15d ns Getting BAR config:", $time()/1000);
    for (int i = 0; i < 6; i = i + 1) begin
      ebfm_cfg_decode_bar(BAR_TABLE_POINTER, i, log2Size, isMem, isPref, is64b);
      $display("INFO: %15d ns   BAR %0d: {log2Size=%0d, isMem=%0d, isPref=%0d, is64b=%0d}", $time()/1000, i, log2Size, isMem, isPref, is64b);
    end
  endtask

  task fpgaRead(ExtChan chan, output Data into);
    ebfm_barrd_wait(BAR_TABLE_POINTER, REG_BAR, 8*chan+4, TMP_BASE_ADDR, 4, 0);
    into = shmem_read(TMP_BASE_ADDR, 4);
  endtask

  task fpgaWrite(ExtChan chan, Data val);
    ebfm_barwr_imm(BAR_TABLE_POINTER, REG_BAR, 8*chan+4, val, 4, 0);
  endtask

  task hostWrite64(int addr, uint64 value);
    shmem_write(addr, value, 8);
  endtask

  function uint64 hostRead64(int addr);
    return shmem_read(addr, 8);
  endfunction
  function uint32 hostRead32(int addr);
    return shmem_read(addr, 4);
  endfunction

  task c2fWriteChunk(Result expecting);
    static int index = 0;  // index into the dvr_rng_pkg::SEQ64 array of precomputed pseudorandom numbers
    static C2FChunkIndex wrPtr = 0;
    const automatic C2FChunkIndex newWrPtr = wrPtr + 1;  // wraps appropriately
    const automatic C2FChunkIndex rdPtr = hostRead32(C2F_RDPTR_ADDR);  // FPGA DMAs its read-pointer here
    if (newWrPtr == rdPtr) begin
      // There's no room for more data; hopefully we're expecting that to be the case
      if (expecting == SUCCESS) begin
        $display(
          "\nFAILURE [%0dns]: Expected success from c2fWriteChunk(wrPtr = %0d, rdPtr = %0d), but it failed!",
          $time()/1000, wrPtr, rdPtr
        );
        $stop(1);
      end
    end else begin
      // There is room for more data; hopefully we're expecting that to be the case
      if (expecting == FAILURE) begin
        $display(
          "\nFAILURE [%0dns]: Expected failure from c2fWriteChunk(wrPtr = %0d, rdPtr = %0d), but it was successful!",
          $time()/1000, wrPtr, rdPtr
        );
        $stop(1);
      end

      // Write each line of this chunk...
      for (int i = 0; i < C2F_CHUNKSIZE/64; i = i + 1) begin
        // First prepare one 64-byte line
        for (int j = 0; j < 64/8; j = j + 1) begin
          hostWrite64(TMP_BASE_ADDR + 8*j, dvr_rng_pkg::SEQ64[index]);
          index = (index + 1) % $size(dvr_rng_pkg::SEQ64);
        end

        // Now write that line to the FPGA
        ebfm_barwr(BAR_TABLE_POINTER, C2F_BAR, wrPtr * C2F_CHUNKSIZE + i * 64, TMP_BASE_ADDR, 64, 0);
      end
      wrPtr = newWrPtr;  // increment wrPtr
    end
  endtask

  // Main program
  initial begin: main
    Data u32;
    uint64 u64;
    bit retCode;
    int tlp, qw;
    automatic F2CChunkIndex rdPtr = 0;
    automatic Result result = SUCCESS;
    //parameter int NUM_QWS = (C2F_NUMCHUNKS-1)*C2F_CHUNKSIZE/8;  // verify all C2F_NUMCHUNKS-1 chunks of CPU->FPGA data
    parameter int NUM_QWS = NUM_ITERATIONS*2;  // verify just a few QWs

    // Setup the RC and EP config spaces
    ebfm_cfg_rp_ep(
      BAR_TABLE_POINTER,  // BAR size/address info for EP
      1,                  // bus number for EP
      1,                  // device number for EP
      512,                // maximum read request size for RC
      1,                  // display EP config space after setup
      1                   // limit the BAR assignments to 4GB address map
    );

    // Get BAR configs
    displayBarConfigs();

    // Do some burst-writes...
    $display("\nINFO: %15d ns Burst-writing 4096 bytes (this'll take a while!)", $time()/1000);
    for (int i = 0; i < C2F_NUMCHUNKS-1; i = i + 1)
      c2fWriteChunk(.expecting(SUCCESS));
    c2fWriteChunk(.expecting(FAILURE));

    // ...and verify readback
    $display("INFO: %15d ns Verifying %0d QWs...", $time()/1000, NUM_QWS);
    for (int i = 0; i < NUM_QWS; i = i + 1) begin
      fpgaRead(pcie_app_pkg::C2FDATA_LSW, .into(u64[31:0]));
      fpgaRead(pcie_app_pkg::C2FDATA_MSW, .into(u64[63:32]));
      if (u64 == dvr_rng_pkg::SEQ64[i % $size(dvr_rng_pkg::SEQ64)]) begin
        $display("INFO: %15d ns   Got QW[%0d]: 0x%s (Y)", $time()/1000, i, himage16(u64));
      end else begin
        $display("INFO: %15d ns   Got QW[%0d]: 0x%s (N)", $time()/1000, i, himage16(u64));
        result = FAILURE;
      end
    end

    // Initialize FPGA
    fpgaWrite(F2C_BASE, F2C_BASE_ADDR/8);  // set base address of FPGA->CPU buffer
    fpgaWrite(MTR_BASE, MTR_BASE_ADDR/8);  // set base address of metrics buffer
    fpgaWrite(DMA_ENABLE, 0);              // reset everything

    // Write to registers...
    $display("\nINFO: %15d ns Writing %0d registers:", $time()/1000, NUM_ITERATIONS);
    for (int i = 0; i < NUM_ITERATIONS; i = i + 1) begin
      $display("INFO: %15d ns   Write[%0d, 0x%s]", $time()/1000, i, himage8(dvr_rng_pkg::SEQ32[i]));
      fpgaWrite(i, dvr_rng_pkg::SEQ32[i]);
    end

    // Read it all back
    $display("\nINFO: %15d ns Reading %0d registers:", $time()/1000, NUM_ITERATIONS);
    for (int i = 0; i < NUM_ITERATIONS; i = i + 1) begin
      fpgaRead(i, .into(u32));
      if (u32 == dvr_rng_pkg::SEQ32[i]) begin
        $display("INFO: %15d ns   Read[%0d] = 0x%s (Y)", $time()/1000, i, himage8(u32));
      end else begin
        $display("INFO: %15d ns   Read[%0d] = 0x%s (N)", $time()/1000, i, himage8(u32));
        result = FAILURE;
      end
    end

    // Try DMA write
    $display("\nINFO: %15d ns Testing DMA write:", $time()/1000);
    fpgaWrite(DMA_ENABLE, 1);  // enable DMA
    for (tlp = 0; tlp < NUM_ITERATIONS; tlp = tlp + 1) begin
      // Wait for a TLP to arrive
      while (rdPtr == hostRead32(F2C_WRPTR_ADDR))
        #8000;  // 8ns
      $display("INFO: %15d ns   TLP %0d (@%0d):", $time()/1000, tlp, rdPtr);
      for (qw = 0; qw < 16; qw = qw + 1) begin
        u64 = hostRead64(rdPtr*128 + qw*8);
        if (tlp*16+qw < 256) begin
          if (u64 === dvr_rng_pkg::SEQ64[tlp*16+qw]) begin
            $display("INFO: %15d ns     %s (Y)", $time()/1000, himage16(u64));
          end else begin
            $display("INFO: %15d ns     %s (N)", $time()/1000, himage16(u64));
            result = FAILURE;
          end
        end else begin
          $display("INFO: %15d ns     %s", $time()/1000, himage16(u64));
        end
      end
      rdPtr = rdPtr + 1;  // wraps appropriately
      fpgaWrite(F2C_RDPTR, rdPtr);  // tell FPGA we're finished with this TLP
      $display();
    end
    fpgaWrite(DMA_ENABLE, 0);  // disable DMA

    // Pass or fail
    if (result) begin
      $display("INFO: %15d ns Tests PASSED!\n", $time()/1000);
      retCode = ebfm_log_stop_sim(1);
    end else begin
      $display("INFO: %15d ns Tests FAILED!\n", $time()/1000);
      retCode = ebfm_log_stop_sim(0);
    end
  end
endmodule

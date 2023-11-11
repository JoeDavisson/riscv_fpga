// RISC-V FPGA Soft Processor
//  Author: Michael Kohn
//   Email: mike@mikekohn.net
//     Web: https://www.mikekohn.net/
//   Board: iceFUN iCE40 HX8K
// License: MIT
//
// Copyright 2023 by Michael Kohn

module riscv
(
  output [7:0] leds,
  output [3:0] column,
  input raw_clk,
  output eeprom_cs,
  output eeprom_clk,
  output eeprom_di,
  input  eeprom_do,
  output speaker_p,
  output speaker_m,
  output ioport_0,
  input  button_reset,
  input  button_halt,
  input  button_program_select,
  input  button_0
);

// iceFUN 8x4 LEDs used for debugging.
reg [7:0] leds_value;
reg [3:0] column_value;

assign leds = leds_value;
assign column = column_value;

// Memory bus (ROM, RAM, peripherals).
reg [15:0] mem_address = 0;
reg [31:0] mem_write = 0;
reg [3:0] mem_write_mask = 0;
wire [31:0] mem_read;
wire mem_data_ready;
reg mem_bus_enable = 0;
reg mem_write_enable = 0;

// Clock.
reg [21:0] count = 0;
reg [4:0] state = 0;
reg [19:0] clock_div;
reg [14:0] delay_loop;
wire clk;
assign clk = clock_div[7];

// Registers.
//wire [31:0] registers [0];
//assign registers[0] = 0;
reg [31:0] registers [31:0];
reg [15:0] pc = 0;

// Instruction
reg [31:0] instruction;
wire [6:0] op;
wire [4:0] rd;
wire [4:0] rs1;
wire [4:0] rs2;
wire [4:0] shamt;
wire [2:0] funct3;
wire [11:0] branch_offset;
wire [2:0] memory_size;
assign op  = instruction[6:0];
assign rd  = instruction[11:7];
assign rs1 = instruction[19:15];
assign rs2 = instruction[24:20];
assign shamt = instruction[24:20];
assign funct3 = instruction[14:12];
assign branch_offset = {
  instruction[31],
  instruction[7],
  instruction[30:25],
  instruction[11:8]
};

// Load / Store.
assign memory_size = instruction[14:12];
reg [31:0] ea;
reg [31:0] ea_aligned;
//reg [31:0] data;

// Lower 6 its of the instruction.
wire [5:0] opcode;
assign opcode = instruction[5:0];

// Eeprom.
reg  [8:0] eeprom_count;
wire [7:0] eeprom_data_out;
reg [10:0] eeprom_address;
reg eeprom_strobe = 0;
wire eeprom_ready;

// Debug.
//reg [7:0] debug_0 = 0;
//reg [7:0] debug_1 = 0;
//reg [7:0] debug_2 = 0;
//reg [7:0] debug_3 = 0;

// This block is simply a clock divider for the raw_clk.
always @(posedge raw_clk) begin
  count <= count + 1;
  clock_div <= clock_div + 1;
end

// Debug: This block simply drives the 8x4 LEDs.
always @(posedge raw_clk) begin
  case (count[9:7])
    3'b000: begin column_value <= 4'b0111; leds_value <= ~registers[7][7:0]; end
    3'b010: begin column_value <= 4'b1011; leds_value <= ~instruction[7:0]; end
    3'b100: begin column_value <= 4'b1101; leds_value <= ~pc[7:0]; end
    3'b110: begin column_value <= 4'b1110; leds_value <= ~state; end
    default: begin column_value <= 4'b1111; leds_value <= 8'hff; end
  endcase
end

parameter STATE_RESET =        0;
parameter STATE_DELAY_LOOP =   1;
parameter STATE_FETCH_OP_0 =   2;
parameter STATE_FETCH_OP_1 =   3;
parameter STATE_START_DECODE = 4;
parameter STATE_EXECUTE_E =    5;
parameter STATE_FETCH_LOAD_1 = 6;

parameter STATE_STORE_0 =      7;
parameter STATE_STORE_1 =      8;

parameter STATE_HALTED =       19;
parameter STATE_ERROR =        20;
parameter STATE_EEPROM_START = 21;
parameter STATE_EEPROM_READ =  22;
parameter STATE_EEPROM_WAIT =  23;
parameter STATE_EEPROM_WRITE = 24;
parameter STATE_EEPROM_DONE =  25;

// 00_000_000
//parameter OP_DCR = 6'b000_001;

function signed [31:0] sign(input signed [31:0] data);
  sign = data;
endfunction

function [31:0] sign12(input [11:0] data);
  sign12 = { {20{ data[11] }}, data[11:0] };
endfunction

`define sign_imm12(data) { {20{ data[31] }}, data[31:20] }

/*
function [31:0] sll(input [31:0] source, input shamt [4:0])
  case (shamt)

  endcase
endfunction
*/

// This block is the main CPU instruction execute state machine.
always @(posedge clk) begin
  if (!button_reset)
    state <= STATE_RESET;
  else if (!button_halt)
    state <= STATE_HALTED;
  else
    case (state)
      STATE_RESET:
        begin
          mem_address <= 0;
          mem_write_enable <= 0;
          mem_write <= 0;
          instruction <= 0;
          delay_loop <= 12000;
          //eeprom_strobe <= 0;
          state <= STATE_DELAY_LOOP;
          registers[0] <= 0;
        end
      STATE_DELAY_LOOP:
        begin
          // This is probably not needed. The chip starts up fine without it.
          if (delay_loop == 0) begin

            // If button is not pushed, start rom.v code otherwise use EEPROM.
            if (button_program_select) begin
              pc <= 16'h4000;
              registers[1] <= 8'hc0;
            end else begin
              pc <= 0;
              registers[1] <= 8'h99;
            end

            //state <= STATE_EEPROM_START;
            state <= STATE_FETCH_OP_0;
          end else begin
            delay_loop <= delay_loop - 1;
          end
        end
      STATE_FETCH_OP_0:
        begin
          mem_bus_enable <= 1;
          mem_write_enable <= 0;
          mem_address <= pc;
          pc <= pc + 4;
          state <= STATE_FETCH_OP_1;
        end
      STATE_FETCH_OP_1:
        begin
          if (mem_data_ready) begin
            mem_bus_enable <= 0;
            instruction <= mem_read;

            state <= STATE_START_DECODE;
          end else begin
            state <= STATE_FETCH_OP_1;
          end
        end
      STATE_START_DECODE:
        begin
          case (op)
            7'b0110111:
              begin
                // lui.
                registers[rd] <= { instruction[31:12], 12'b0 };
                state <= STATE_FETCH_OP_0;
              end
            7'b0010111:
              begin
                // auipc.
                registers[rd] <= pc + { instruction[31:12], 12'b0 };
                state <= STATE_FETCH_OP_0;
              end
            7'b1101111:
              begin
                // jal.
                registers[rd] <= pc;
                // FIXME: This should be signed.
                pc <= pc + {
                  instruction[31],
                  instruction[19:12],
                  instruction[20],
                  instruction[30:21],
                  1'b0
                };
                state <= STATE_FETCH_OP_0;
              end
            7'b1100111:
              begin
                // jalr.
                registers[rd] <= pc;
                pc <= (pc + registers[rd] + sign12(instruction[31:20])) & 32'hfffffffc;
                state <= STATE_FETCH_OP_0;
              end
            7'b1100011:
              begin
                // branch.
                case (funct3)
                  3'b000:
                    if (registers[rs1] == registers[rs2])
                      pc <= pc + sign12(branch_offset);
                  3'b001:
                    if (registers[rs1] != registers[rs2])
                      pc <= pc + sign12(branch_offset);
                  3'b100:
                    if (sign(registers[rs1]) < sign(registers[rs2]))
                      pc <= pc + sign12(branch_offset);
                  3'b101:
                    if (sign(registers[rs1]) >= sign(registers[rs2]))
                      pc <= pc + sign12(branch_offset);
                  3'b110:
                    if (registers[rs1] < registers[rs2])
                      pc <= pc + sign12(branch_offset);
                  3'b111:
                    if (registers[rs1] >= registers[rs2])
                      pc <= pc + sign12(branch_offset);
                endcase
                state <= STATE_FETCH_OP_0;
              end
            7'b0000011:
              begin
                // Load.
                ea <= registers[rs1] + sign12(instruction[31:20]);
                mem_bus_enable <= 1;
                mem_write_enable <= 0;
                mem_address <= registers[rs1] + sign12(instruction[31:20]);
                state <= STATE_FETCH_LOAD_1;
              end
            7'b0100011:
              begin
                // Store.
                ea <= registers[rs1] + sign12( { instruction[31:25], instruction[11:7] } );
                mem_address <= registers[rs1] + sign12( { instruction[31:25], instruction[11:7] } );
                mem_bus_enable <= 0;
                state <= STATE_STORE_0;
              end
            7'b0010011:
              begin
                // ALU immediate.
                case (funct3)
                  3'b000: registers[rd] <= registers[rs1] + sign12(instruction[31:20]);
                  3'b010: registers[rd] <= registers[rs1] < sign12(instruction[31:20]);
                  3'b011: registers[rd] <= registers[rs1] < instruction[31:20];
                  3'b100: registers[rd] <= registers[rs1] ^ sign12(instruction[31:20]);
                  3'b110: registers[rd] <= registers[rs1] | sign12(instruction[31:20]);
                  3'b111: registers[rd] <= registers[rs1] & sign12(instruction[31:20]);
                  // Shift.
                  3'b001: registers[rd] <= registers[rs1] << shamt;
                  3'b101:
                    if (instruction[31:25] == 0)
                      registers[rd] <= registers[rs1] >> shamt;
                    else
                      registers[rd] <= sign(registers[rs1]) >> shamt;
                endcase

                state <= STATE_FETCH_OP_0;
              end
            7'b0110011:
              begin
                // ALU reg, reg.
                case (funct3)
                  3'b000:
                    if (instruction[31:25] == 0)
                      registers[rd] <= registers[rs1] + registers[rs2];
                    else
                      registers[rd] <= registers[rs1] - registers[rs2];
                  3'b001: registers[rd] <= registers[rs1] << registers[rs2];
                  3'b010: registers[rd] <= sign(registers[rs1]) < sign(registers[rs2]);
                  3'b011: registers[rd] <= registers[rs1] < registers[rs1];
                  3'b100: registers[rd] <= registers[rs1] ^ registers[rs1];
                  3'b101:
                    if (instruction[31:25] == 0)
                      registers[rd] <= registers[rs1] >> registers[rs2];
                    else
                      registers[rd] <= sign(registers[rs1]) >> registers[rs2];
                  3'b110: registers[rd] <= registers[rs1] | registers[rs1];
                  3'b111: registers[rd] <= registers[rs1] & registers[rs1];
                endcase
              end
            7'b1110011:
              begin
                state <= STATE_EXECUTE_E;
              end
            default
              begin
                state <= STATE_HALTED;
              end
          endcase
        end
      STATE_EXECUTE_E:
        begin
          // Since this core only supports "ebreak", send all instructions
          // to the halted state.
          state <= STATE_HALTED;
        end
      STATE_FETCH_LOAD_1:
        begin
          if (mem_data_ready) begin
            mem_bus_enable <= 0;

            case (memory_size[1:0])
              3'b00:
                begin
                  case (ea[1:0])
                    0:
                      begin
                        registers[rd][7:0] <= mem_read[7:0];
                        registers[rd][31:8] <= { {24{ mem_read[7] & memory_size[2] } } };
                      end
                    1:
                      begin
                        registers[rd][7:0] <= mem_read[15:8];
                        registers[rd][31:8] <= { {24{ mem_read[15] & memory_size[2] } } };
                      end
                    2:
                      begin
                        registers[rd][7:0] <= mem_read[23:16];
                        registers[rd][31:8] <= { {24{ mem_read[23] & memory_size[2] } } };
                      end
                    3:
                      begin
                        registers[rd][7:0] <= mem_read[31:24];
                        registers[rd][31:8] <= { {24{ mem_read[31] & memory_size[2] } } };
                      end
                  endcase
                end
              3'b01:
                begin
                  case (ea[1:0])
                    0,1:
                      begin
                        registers[rd][15:0] <= mem_read[15:0];
                        registers[rd][31:8] <= { {16{ mem_read[15] & memory_size[2] } } };
                      end
                    2,3:
                      begin
                        registers[rd][15:0] <= mem_read[31:16];
                        registers[rd][31:8] <= { {16{ mem_read[31] & memory_size[2] } } };
                      end
                  endcase
                end
              3'b10:
                begin
                  registers[rd] <= mem_read;
                end
            endcase

            state <= STATE_FETCH_OP_0;
          end else begin
            state <= STATE_FETCH_LOAD_1;
          end
        end
      STATE_STORE_0:
        begin
          case (funct3)
            3'b000:
              begin
                case (ea[1:0])
                  2'b00:
                    begin
                      mem_write <= { 24'h0000, registers[rs2][7:0] };
                      mem_write_mask <= 4'b1110;
                    end
                  2'b01:
                    begin
                      mem_write <= { 16'h0000, registers[rs2][7:0], 8'h00 };
                      mem_write_mask <= 4'b1101;
                    end
                  2'b10:
                    begin
                      mem_write <= { 8'h00, registers[rs2][7:0], 16'h0000 };
                      mem_write_mask <= 4'b1011;
                    end
                  2'b11:
                    begin
                      mem_write <= { registers[rs2][7:0], 24'h0000 };
                      mem_write_mask <= 4'b0111;
                    end
                endcase
              end
            3'b001:
              begin
                case (ea[1:0])
                  2'b00:
                    begin
                      mem_write <= { 16'h0000, registers[rs2][15:0] };
                      mem_write_mask <= 4'b1100;
                    end
                  2'b10:
                    begin
                      mem_write <= { registers[rs2][15:0], 16'h0000 };
                      mem_write_mask <= 4'b0011;
                    end
                endcase
              end
            3'b010:
              begin
                mem_write <= registers[rs2];
                mem_write_mask <= 4'b0000;
              end
          endcase

          mem_write_enable <= 1;
          mem_bus_enable <= 1;
          state <= STATE_STORE_1;
        end
      STATE_STORE_1:
        begin
          if (mem_data_ready) begin
            mem_bus_enable <= 0;
            mem_write_enable <= 0;
            state <= STATE_FETCH_OP_0;
          end
        end
      STATE_HALTED:
        begin
          state <= STATE_HALTED;
        end
    endcase
end

memory_bus memory_bus_0(
  .address      (mem_address),
  .data_in      (mem_write),
  .write_mask   (mem_write_mask),
  .data_read    (mem_read),
  .data_ready   (mem_data_ready),
  .bus_enable   (mem_bus_enable),
  .write_enable (mem_write_enable),
  .clk          (clk),
  .raw_clk      (raw_clk),
  .double_clk   (clock_div[6]),
  .speaker_p    (speaker_p),
  .speaker_m    (speaker_m),
  .ioport_0     (ioport_0),
  .button_0     (button_0),
  .reset        (~button_reset)
  //.debug        (debug_1)
);

eeprom eeprom_0
(
  .address    (eeprom_address),
  .strobe     (eeprom_strobe),
  .raw_clk    (raw_clk),
  .eeprom_cs  (eeprom_cs),
  .eeprom_clk (eeprom_clk),
  .eeprom_di  (eeprom_di),
  .eeprom_do  (eeprom_do),
  .ready      (eeprom_ready),
  .data_out   (eeprom_data_out)
);

endmodule


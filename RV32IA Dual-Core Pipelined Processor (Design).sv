module nerv #(
    parameter [31:0] RESET_ADDR = 32'h 0000_0000,
    parameter integer NUMREGS = 32
) (
    input clock,
    input reset,
    output trap,

    // Instruction memory
    output [31:0] imem_addr,
    input  [31:0] imem_data,

    // Data memory
    output        dmem_valid,
    output        dmem_wr_is_cond,
    output [31:0] dmem_addr,
    output [ 3:0] dmem_wstrb,
    output [31:0] dmem_wdata,
    input  [31:0] dmem_rdata,

    output dmem_resv,      // LR.W reservation request
    input  dmem_cond       // SC.W success/failure (1=success, 0=fail)
);

    //Register File and 
    logic [31:0] regfile [0:NUMREGS-1];
    logic [31:0] pc;
    logic [31:0] npc;

    //Memory-related signals
    logic mem_wr_enable;
    logic [31:0] mem_wr_addr;
    logic [31:0] mem_wr_data;
    logic [3:0] mem_wr_strb;

    logic mem_rd_enable;
    logic [31:0] mem_rd_addr;
    logic [4:0] mem_rd_reg;
    logic [4:0] mem_rd_func;

    logic mem_rd_enable_q;
    logic [4:0] mem_rd_reg_q;
    logic [4:0] mem_rd_func_q;
    logic is_sc_q_delayed;

    //Atomic Insn flags/control signals
    logic is_lr_q;        // Currently LR.W
    logic is_sc_q;        // Currently SC.W

    //state regs
    logic [31:0] IF_pc;
    logic [31:0] IF_insn;
    logic [31:0] EX_pc;
    logic [31:0] EX_insn;
    logic [31:0] EX_rs1_value;
    logic [31:0] EX_rs2_value;

    //branch control
    logic branch_taken, branch_taken_q;
    logic [31:0] branch_target, branch_target_q;

    //trap
    logic trapped;
    logic trapped_q;
    assign trap = trapped;

    logic [31:0] imem_addr_q;
    logic reset_q;

    //delayed copies of mem_rd
    always_ff @(posedge clock) begin
        mem_rd_enable_q <= mem_rd_enable;
        mem_rd_reg_q <= mem_rd_reg;
        mem_rd_func_q <= mem_rd_func;
        is_sc_q_delayed <= is_sc_q;
        if (reset) begin
            mem_rd_enable_q <= 0;
            is_sc_q_delayed <= 0;
        end
    end

    // memory signals
    assign dmem_valid = mem_wr_enable || mem_rd_enable;
    assign dmem_addr  = mem_wr_enable ? mem_wr_addr : mem_rd_enable ? mem_rd_addr : 32'hx;
    assign dmem_wstrb = mem_wr_enable ? mem_wr_strb : mem_rd_enable ? 4'h0 : 4'hx;
    assign dmem_wdata = mem_wr_enable ? mem_wr_data : 32'hx;

    //Data memory interface (atomic)
    assign dmem_resv = is_lr_q;
    assign dmem_wr_is_cond = is_sc_q;

    //stall branch 
    always_ff @(posedge clock) begin
        imem_addr_q <= imem_addr;
        branch_taken_q <= branch_taken;
        branch_target_q <= branch_target;
    end

    // Instruction memory address with stall and branch handling
    assign imem_addr = (trap || mem_rd_enable_q) ? imem_addr_q : 
                       (branch_taken || branch_taken_q) ? branch_target : npc;

    // components of the instruction
    wire [6:0] IF_insn_funct7;
    wire [4:0] IF_insn_rs2;
    wire [4:0] IF_insn_rs1;
    wire [2:0] IF_insn_funct3;
    wire [4:0] IF_insn_rd;
    wire [6:0] IF_insn_opcode;
    
    //split R-type instruction - see section 2.2 of RiscV spec
    assign {IF_insn_funct7, IF_insn_rs2, IF_insn_rs1, IF_insn_funct3, IF_insn_rd, IF_insn_opcode} = IF_insn;

    // setup for I, S, B & J type instructions
    wire [11:0] IF_imm_i = IF_insn[31:20];
    wire [11:0] IF_imm_s = {IF_insn_funct7, IF_insn_rd};
    wire [12:0] IF_imm_b = {IF_insn[31], IF_insn[7], IF_insn[30:25], IF_insn[11:8], 1'b0};
    wire [20:0] IF_imm_j = {IF_insn[31], IF_insn[19:12], IF_insn[20], IF_insn[30:21], 1'b0};

    wire [31:0] IF_imm_i_sext = {{20{IF_imm_i[11]}}, IF_imm_i};
    wire [31:0] IF_imm_s_sext = {{20{IF_imm_s[11]}}, IF_imm_s};
    wire [31:0] IF_imm_b_sext = {{19{IF_imm_b[12]}}, IF_imm_b};
    wire [31:0] IF_imm_j_sext = {{11{IF_imm_j[20]}}, IF_imm_j};

    // Register File Read
    wire [31:0] IF_rs1_raw = (IF_insn_rs1 == 5'd0) ? 32'd0 : regfile[IF_insn_rs1];
    wire [31:0] IF_rs2_raw = (IF_insn_rs2 == 5'd0) ? 32'd0 : regfile[IF_insn_rs2];

    // Data Hazard (Forwarding)
    logic next_wr;
    logic [31:0] next_rd;
    
    logic [6:0] EX_insn_funct7;
    logic [4:0] EX_insn_rs2;
    logic [4:0] EX_insn_rs1;
    logic [2:0] EX_insn_funct3;
    logic [4:0] EX_insn_rd;
    logic [6:0] EX_insn_opcode;

    wire ex_we = next_wr && (EX_insn_rd != 5'd0);
    wire [31:0] ex_wdata = next_rd;

    // Bypass from EX result to IF operands when they match
    wire [31:0] IF_rs1_value = (ex_we && (IF_insn_rs1 == EX_insn_rd)) ? ex_wdata : IF_rs1_raw;
    wire [31:0] IF_rs2_value = (ex_we && (IF_insn_rs2 == EX_insn_rd)) ? ex_wdata : IF_rs2_raw;

    // EX Stage Signals
    logic [31:0] EX_imm_i_sext;
    logic [31:0] EX_imm_s_sext;
    logic [31:0] EX_imm_b_sext;
    logic [31:0] EX_imm_j_sext;

    //Instruction fetch stage
    always_ff @(posedge clock) begin
        if (reset) begin
            IF_insn <= 32'h00000013; // NOP
            IF_pc <= 32'h0;
        end else if (branch_taken || branch_taken_q) begin
            IF_insn <= 32'h00000013; // NOP (flush)
            IF_pc <= pc;
        end else begin
            IF_insn <= imem_data;
            IF_pc <= pc;
        end
    end

    // IF/EX Pipeline Register
    always_ff @(posedge clock) begin
        if (reset) begin
            EX_pc <= 0;
            EX_insn <= 0;
            EX_rs1_value <= 0;
            EX_rs2_value <= 0;
            EX_insn_rd <= 0;
            EX_insn_opcode <= 0;
            EX_insn_funct7 <= 0;
            EX_insn_funct3 <= 0;
            EX_insn_rs1 <= 0;
            EX_insn_rs2 <= 0;
            EX_imm_i_sext <= 0;
            EX_imm_s_sext <= 0;
            EX_imm_b_sext <= 0;
            EX_imm_j_sext <= 0;
        end else begin
            EX_pc <= IF_pc;
            EX_insn <= IF_insn;
            EX_rs1_value <= IF_rs1_value;
            EX_rs2_value <= IF_rs2_value;
            EX_insn_rd <= IF_insn_rd;
            EX_insn_opcode <= IF_insn_opcode;
            EX_insn_funct7 <= IF_insn_funct7;
            EX_insn_funct3 <= IF_insn_funct3;
            EX_insn_rs1 <= IF_insn_rs1;
            EX_insn_rs2 <= IF_insn_rs2;
            EX_imm_i_sext <= IF_imm_i_sext;
            EX_imm_s_sext <= IF_imm_s_sext;
            EX_imm_b_sext <= IF_imm_b_sext;
            EX_imm_j_sext <= IF_imm_j_sext;
        end
    end

    // Opcode Definitions
    localparam OPCODE_LOAD       = 7'b00_000_11;
    localparam OPCODE_STORE      = 7'b01_000_11;
    localparam OPCODE_BRANCH     = 7'b11_000_11;
    localparam OPCODE_JALR       = 7'b11_001_11;
    localparam OPCODE_JAL        = 7'b11_011_11;
    localparam OPCODE_OP_IMM     = 7'b00_100_11;
    localparam OPCODE_OP         = 7'b01_100_11;
    localparam OPCODE_AUIPC      = 7'b00_101_11;
    localparam OPCODE_LUI        = 7'b01_101_11;
    localparam OPCODE_AMO        = 7'b01_011_11;

    //illinsn = 1, when illegal insn detected
    logic illinsn;

    //Combinational/Execute Stage
    always_comb begin
        // Default values
        npc = pc + 4;
        branch_taken = 0;
        branch_target = 32'hx;
        next_wr = 0;
        next_rd = 0;
        illinsn = 0;
        is_lr_q = 0;
        is_sc_q = 0;

        mem_wr_enable = 0;
        mem_wr_addr = 32'hx;
        mem_wr_data = 32'hx;
        mem_wr_strb = 4'hx;

        mem_rd_enable = 0;
        mem_rd_addr = 32'hx;
        mem_rd_reg = 5'hx;
        mem_rd_func = 5'hx;

        // Instruction sets execution (actson opcodes defined earlier)
        case (EX_insn_opcode)
            OPCODE_LUI: begin
                next_wr = 1;
                next_rd = {EX_insn[31:12], 12'b0};
            end

            OPCODE_AUIPC: begin
                next_wr = 1;
                next_rd = EX_pc + {EX_insn[31:12], 12'b0};
            end

            //J-type
            OPCODE_JAL: begin
                next_wr = 1;
                next_rd = npc;
                branch_taken = 1;
                branch_target = EX_pc + EX_imm_j_sext;
                if (branch_target[1:0] != 2'b00) begin
                    illinsn = 1;
                    branch_target = branch_target & ~32'b11;
                end
            end

            OPCODE_JALR: begin
                if (EX_insn_funct3 == 3'b000) begin
                    next_wr = 1;
                    next_rd = npc;
                    branch_taken = 1;
                    branch_target = (EX_rs1_value + EX_imm_i_sext) & ~32'b1;
                    if (branch_target[1:0] != 2'b00) begin
                        illinsn = 1;
                        branch_target = branch_target & ~32'b11;
                    end
                end else begin
                    illinsn = 1;
                end
            end

            //B-type
            OPCODE_BRANCH: begin
                case (EX_insn_funct3)
                    3'b000: if (EX_rs1_value == EX_rs2_value) begin 
                        branch_taken = 1; 
                        branch_target = EX_pc + EX_imm_b_sext; 
                    end
                    3'b001: if (EX_rs1_value != EX_rs2_value) begin 
                        branch_taken = 1; 
                        branch_target = EX_pc + EX_imm_b_sext; 
                    end
                    3'b100: if ($signed(EX_rs1_value) < $signed(EX_rs2_value)) begin 
                        branch_taken = 1; 
                        branch_target = EX_pc + EX_imm_b_sext; 
                    end
                    3'b101: if ($signed(EX_rs1_value) >= $signed(EX_rs2_value)) begin 
                        branch_taken = 1; 
                        branch_target = EX_pc + EX_imm_b_sext; 
                    end
                    3'b110: if (EX_rs1_value < EX_rs2_value) begin 
                        branch_taken = 1; 
                        branch_target = EX_pc + EX_imm_b_sext; 
                    end
                    3'b111: if (EX_rs1_value >= EX_rs2_value) begin 
                        branch_taken = 1; 
                        branch_target = EX_pc + EX_imm_b_sext; 
                    end
                    default: illinsn = 1;
                endcase
                if (branch_taken && branch_target[1:0] != 2'b00) begin
                    illinsn = 1;
                    branch_target = branch_target & ~32'b11;
                end
            end

            //Load
            OPCODE_LOAD: begin
                mem_rd_addr = EX_rs1_value + EX_imm_i_sext;
                casez ({EX_insn_funct3, mem_rd_addr[1:0]})
                    5'b000_zz, 5'b001_z0, 5'b010_00, 5'b100_zz, 5'b101_z0: begin
                        mem_rd_enable = 1;
                        mem_rd_reg = EX_insn_rd;
                        mem_rd_func = {mem_rd_addr[1:0], EX_insn_funct3};
                        mem_rd_addr = {mem_rd_addr[31:2], 2'b00};
                    end
                    default: illinsn = 1;
                endcase
            end

            //Store
            OPCODE_STORE: begin
                mem_wr_addr = EX_rs1_value + EX_imm_s_sext;
                casez ({EX_insn_funct3, mem_wr_addr[1:0]})
                    5'b000_zz, 5'b001_z0, 5'b010_00: begin
                        mem_wr_enable = 1;
                        mem_wr_data = EX_rs2_value;
                        case (EX_insn_funct3)
                            3'b000: mem_wr_strb = 4'b0001;
                            3'b001: mem_wr_strb = 4'b0011;
                            3'b010: mem_wr_strb = 4'b1111;
                            default: illinsn = 1;
                        endcase
                        mem_wr_data = mem_wr_data << (8*mem_wr_addr[1:0]);
                        mem_wr_strb = mem_wr_strb << mem_wr_addr[1:0];
                        mem_wr_addr = {mem_wr_addr[31:2], 2'b00};
                    end
                    default: illinsn = 1;
                endcase
            end

            //I-type
            OPCODE_OP_IMM: begin
                casez ({EX_insn_funct7, EX_insn_funct3})
                    10'bzzzzzzz_000: begin next_wr = 1; next_rd = EX_rs1_value + EX_imm_i_sext; end
                    10'bzzzzzzz_010: begin next_wr = 1; next_rd = ($signed(EX_rs1_value) < $signed(EX_imm_i_sext)) ? 32'd1 : 32'd0; end
                    10'bzzzzzzz_011: begin next_wr = 1; next_rd = (EX_rs1_value < EX_imm_i_sext) ? 32'd1 : 32'd0; end
                    10'bzzzzzzz_100: begin next_wr = 1; next_rd = EX_rs1_value ^ EX_imm_i_sext; end
                    10'bzzzzzzz_110: begin next_wr = 1; next_rd = EX_rs1_value | EX_imm_i_sext; end
                    10'bzzzzzzz_111: begin next_wr = 1; next_rd = EX_rs1_value & EX_imm_i_sext; end
                    10'b0000000_001: begin next_wr = 1; next_rd = EX_rs1_value << EX_insn[24:20]; end
                    10'b0000000_101: begin next_wr = 1; next_rd = EX_rs1_value >> EX_insn[24:20]; end
                    10'b0100000_101: begin next_wr = 1; next_rd = $signed(EX_rs1_value) >>> EX_insn[24:20]; end
                    default: illinsn = 1;
                endcase
            end

            //R-type
            OPCODE_OP: begin
                case ({EX_insn_funct7, EX_insn_funct3})
                    10'b0000000_000: begin next_wr = 1; next_rd = EX_rs1_value + EX_rs2_value; end
                    10'b0100000_000: begin next_wr = 1; next_rd = EX_rs1_value - EX_rs2_value; end
                    10'b0000000_001: begin next_wr = 1; next_rd = EX_rs1_value << EX_rs2_value[4:0]; end
                    10'b0000000_010: begin next_wr = 1; next_rd = ($signed(EX_rs1_value) < $signed(EX_rs2_value)) ? 32'd1 : 32'd0; end
                    10'b0000000_011: begin next_wr = 1; next_rd = (EX_rs1_value < EX_rs2_value) ? 32'd1 : 32'd0; end
                    10'b0000000_100: begin next_wr = 1; next_rd = EX_rs1_value ^ EX_rs2_value; end
                    10'b0000000_101: begin next_wr = 1; next_rd = EX_rs1_value >> EX_rs2_value[4:0]; end
                    10'b0100000_101: begin next_wr = 1; next_rd = $signed(EX_rs1_value) >>> EX_rs2_value[4:0]; end
                    10'b0000000_110: begin next_wr = 1; next_rd = EX_rs1_value | EX_rs2_value; end
                    10'b0000000_111: begin next_wr = 1; next_rd = EX_rs1_value & EX_rs2_value; end
                    default: illinsn = 1;
                endcase
            end

            OPCODE_AMO: begin
                case ({EX_insn[31:27], EX_insn_funct3})
                    8'b00010_010: begin // LR.W (similar to LW)
                        is_lr_q = 1;
                        mem_rd_enable = 1;
                        mem_rd_addr = {EX_rs1_value[31:2], 2'b00};
                        mem_rd_reg = EX_insn_rd;
                        mem_rd_func = {2'b00, 3'b010};
                    end
                    8'b00011_010: begin // SC.W
                        is_sc_q = 1;
                        // Trigger stall
                        mem_rd_enable = 1;
                        mem_rd_reg = EX_insn_rd;
                        mem_rd_func = 5'b11111;
                        mem_rd_addr = {EX_rs1_value[31:2], 2'b00};
                        // Perform conditional write
                        mem_wr_enable = 1;
                        mem_wr_addr = {EX_rs1_value[31:2], 2'b00};
                        mem_wr_data = EX_rs2_value;
                        mem_wr_strb = 4'b1111;
                    end
                    default: illinsn = 1;
                endcase
            end

            default: illinsn = 1;
        endcase

        // Stall pipeline if last instruction was load
        if (mem_rd_enable_q) begin
            npc = EX_pc;
            next_wr = 0;
            illinsn = 0;
            mem_rd_enable = 0;
            mem_wr_enable = 0;
            is_lr_q = 0;
            is_sc_q = 0;
        end

        // Reset handling
        if (reset || reset_q) begin
            npc = RESET_ADDR;
            next_wr = 0;
            illinsn = 0;
            mem_rd_enable = 0;
            mem_wr_enable = 0;
            is_lr_q = 0;
            is_sc_q = 0;
        end
    end

    // Memory load data processing
    logic [31:0] mem_rdata;
    wire [31:0] mem_rdata_aligned = dmem_rdata >> (8*mem_rd_func_q[4:3]);

    always_comb begin
        if (is_sc_q_delayed) begin
            // SC.W = 0: success, 1: failure
            mem_rdata = dmem_cond ? 32'd0 : 32'd1;
        end else begin
            case (mem_rd_func_q[2:0])
                3'b000: mem_rdata = {{24{mem_rdata_aligned[7]}}, mem_rdata_aligned[7:0]};   // LB
                3'b001: mem_rdata = {{16{mem_rdata_aligned[15]}}, mem_rdata_aligned[15:0]}; // LH
                3'b010: mem_rdata = mem_rdata_aligned;                                       // LW
                3'b100: mem_rdata = {24'd0, mem_rdata_aligned[7:0]};                        // LBU
                3'b101: mem_rdata = {16'd0, mem_rdata_aligned[15:0]};                       // LHU
                default: mem_rdata = mem_rdata_aligned;
            endcase
        end
    end

    //updates every posedge cycle
    always_ff @(posedge clock) begin
        reset_q <= reset;
        trapped_q <= trapped;

        if (!trapped && !reset && !reset_q) begin
            if (illinsn) begin
                trapped <= 1;
            end

            // PC update
            if (branch_taken || branch_taken_q)
                pc <= branch_target;
            else
                pc <= npc;

            // Register writeback
            if (mem_rd_enable_q && (mem_rd_reg_q != 5'd0)) begin
                regfile[mem_rd_reg_q] <= mem_rdata;
            end else if (next_wr && (EX_insn_rd != 5'd0)) begin
                regfile[EX_insn_rd] <= next_rd;
            end

            regfile[0] <= 32'd0; // x0 is immutable, always remains zero as per RISC-V Specs
        end

        if (trapped)
            $display("regfile[10]=%d", regfile[10]);

        if (reset || reset_q) begin
            pc <= RESET_ADDR;
            trapped <= 0;
        end
    end

endmodule

/*********************************** RAM *****************************************************/

module multicore_memory #(
    parameter MEM_ADDR_WIDTH = 17,
    parameter string fname, 
    parameter RESV_BITS = 12
) (
    input clock,
    input reset,

    // Core 0
    input  [31:0] imem_addr0,
    output [31:0] imem_data0,
    input         dmem_valid0,
    input         dmem_wr_is_cond0,
    input  [31:0] dmem_addr0,
    input  [ 3:0] dmem_wstrb0,
    input  [31:0] dmem_wdata0,
    output [31:0] dmem_rdata0,

    // Core 1   
    input  [31:0] imem_addr1,
    output [31:0] imem_data1,
    input         dmem_valid1,
    input         dmem_wr_is_cond1,
    input  [31:0] dmem_addr1,
    input  [ 3:0] dmem_wstrb1,
    input  [31:0] dmem_wdata1,
    output [31:0] dmem_rdata1,

    input  [1:0] dmem_resv,    // reservations dmem_resv[1]=core_1, dmem_resv[0]=core_0
    output reg [1:0] dmem_cond // conditional dmem_cond[1]=core_1, dmem_cond[0]=core_0
);

    // THE ACTUAL MEMORY
    reg [7:0] mem [0:(1<<MEM_ADDR_WIDTH)-1];

    //Initialisation
    reg [RESV_BITS-1:0] resv_addr0, resv_addr1;
    reg resv_valid0, resv_valid1;
    
    // Calculate reservation block ID from address
    wire [RESV_BITS-1:0] resv_id0 = dmem_addr0[11+RESV_BITS:12];
    wire [RESV_BITS-1:0] resv_id1 = dmem_addr1[11+RESV_BITS:12];

    //Run firmwarefile
    initial begin
        $readmemh(fname, mem);
        resv_valid0 = 0;
        resv_valid1 = 0;
    end
    
    //Imem data core0 (initialisation the reg blocks)
    assign imem_data0 = {mem[imem_addr0[MEM_ADDR_WIDTH-1:0]+3], 
            mem[imem_addr0[MEM_ADDR_WIDTH-1:0]+2], 
            mem[imem_addr0[MEM_ADDR_WIDTH-1:0]+1], 
            mem[imem_addr0[MEM_ADDR_WIDTH-1:0]+0]};
    
    //Imem data core1 (initialisation the reg blocks)
    assign imem_data1 = {mem[imem_addr1[MEM_ADDR_WIDTH-1:0]+3], 
            mem[imem_addr1[MEM_ADDR_WIDTH-1:0]+2], 
            mem[imem_addr1[MEM_ADDR_WIDTH-1:0]+1], 
            mem[imem_addr1[MEM_ADDR_WIDTH-1:0]+0]};

    // Dmem read data core0 (initialisation the reg blocks)
    assign dmem_rdata0 = {mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+3], 
            mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+2], 
            mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+1], 
            mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+0]};
    
    // Dmem read data core1 (initialisation the reg blocks)
    assign dmem_rdata1 = {mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+3], 
            mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+2], 
            mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+1], 
            mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+0]};

    //Memory Write and Reservation Logic
    always_ff @(posedge clock) begin
        if (reset) begin
            resv_valid0 <= 0;
            resv_valid1 <= 0;
            dmem_cond <= 2'b00;
        end else begin
            // Default: failed SC
            dmem_cond <= 2'b00;

            
            // Core0 (LR.W)
            if (dmem_valid0 && dmem_resv[0] && !dmem_wr_is_cond0) begin
                resv_valid0 <= 1'b1;
                resv_addr0 <= resv_id0;
            end

            // Core0 (SC.W)
            if (dmem_valid0 && dmem_wr_is_cond0) begin
                // Check if reservation is valid and matches
                if (resv_valid0 && (resv_id0 == resv_addr0)) begin
                    // if 1: Write to memory
                    if (dmem_wstrb0[0]) mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+0] <= dmem_wdata0[7:0];
                    if (dmem_wstrb0[1]) mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+1] <= dmem_wdata0[15:8];
                    if (dmem_wstrb0[2]) mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+2] <= dmem_wdata0[23:16];
                    if (dmem_wstrb0[3]) mem[dmem_addr0[MEM_ADDR_WIDTH-1:0]+3] <= dmem_wdata0[31:24];
                    dmem_cond[0] <= 1'b1; // Signal successful SC.W
                end
                // Clear all reservationsfrom both cores
                if (resv_valid0 && (resv_id0 == resv_addr0))
                    resv_valid0 <= 1'b0;
                if (resv_valid1 && (resv_id0 == resv_addr1))
                    resv_valid1 <= 1'b0;
            end

            
            // Core1(LR.W)
            if (dmem_valid1 && dmem_resv[1] && !dmem_wr_is_cond1) begin
                resv_valid1 <= 1'b1;
                resv_addr1 <= resv_id1;
            end

            // Core1 (SC.W)
            if (dmem_valid1 && dmem_wr_is_cond1) begin
                // Check if reservation is valid and matches
                if (resv_valid1 && (resv_id1 == resv_addr1)) begin
                    // If 1: Write to memory
                    // Priority: Core 0 > Core 1
                    if (dmem_wstrb1[0]) mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+0] <= dmem_wdata1[7:0];
                    if (dmem_wstrb1[1]) mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+1] <= dmem_wdata1[15:8];
                    if (dmem_wstrb1[2]) mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+2] <= dmem_wdata1[23:16];
                    if (dmem_wstrb1[3]) mem[dmem_addr1[MEM_ADDR_WIDTH-1:0]+3] <= dmem_wdata1[31:24];
                    dmem_cond[1] <= 1'b1; // Signal successful SC.W
                end
                // Clear all reservations from both cores
                if (resv_valid0 && (resv_id1 == resv_addr0))
                    resv_valid0 <= 1'b0;
                if (resv_valid1 && (resv_id1 == resv_addr1))
                    resv_valid1 <= 1'b0;
            end
        end
    end

endmodule
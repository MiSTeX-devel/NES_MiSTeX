`timescale 1ns/10ps
module  pll_0002(
	input  wire refclk,
	input  wire rst,
	output wire outclk_0,
	output wire outclk_1,
	output wire outclk_2,
	output wire locked
);

	wire feedback;
	
	PLLE2_ADV #(
		.CLKFBOUT_MULT(6'd24),
		.CLKIN1_PERIOD(20.0),
		.CLKOUT0_DIVIDE(7'd14), // 85.909088 MHz =~ 50MHz * 24 / 14
		.CLKOUT0_PHASE(1'd0),
		.CLKOUT1_DIVIDE(7'd28), // 42.954544 MHz =~ 50MHz * 24 / 28
		.CLKOUT1_PHASE(1'd0),
		.CLKOUT2_DIVIDE(7'd56), // 21.477272MHz  =~ 50MHz * 24 / 56
		.CLKOUT2_PHASE(1'd0),
		.DIVCLK_DIVIDE(1'd1),
		.REF_JITTER1(0.01),
		.STARTUP_WAIT("FALSE")
	) CORE_PLL (
		.CLKFBIN(feedback),
		.CLKIN1(refclk),
		.PWRDWN(1'b0),
		.RST(rst),
		.CLKFBOUT(feedback),
		.CLKOUT0(outclk_0),
		.CLKOUT1(outclk_1),
		.CLKOUT2(outclk_2),
		.LOCKED(locked)
);
	
endmodule


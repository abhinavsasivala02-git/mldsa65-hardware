`timescale 1ns/1ps

/*
 * Copyright (C) 2026
 * Author: Abhinav S <abhinavsasivala02@gmail.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 */

module zeta_rom (
    input  wire        clk,
    input  wire [7:0]  addr,
    output reg  [22:0] data
);

    // Combinational lookup
    reg [22:0] rom_out;

    always @(*) begin
        case (addr)
            8'd0:   rom_out = 23'd4193792;
            8'd1:   rom_out = 23'd25847;
            8'd2:   rom_out = 23'd5771523;
            8'd3:   rom_out = 23'd7861508;
            8'd4:   rom_out = 23'd237124;
            8'd5:   rom_out = 23'd7602457;
            8'd6:   rom_out = 23'd7504169;
            8'd7:   rom_out = 23'd466468;
            8'd8:   rom_out = 23'd1826347;
            8'd9:   rom_out = 23'd2353451;
            8'd10:  rom_out = 23'd8021166;
            8'd11:  rom_out = 23'd6288512;
            8'd12:  rom_out = 23'd3119733;
            8'd13:  rom_out = 23'd5495562;
            8'd14:  rom_out = 23'd3111497;
            8'd15:  rom_out = 23'd2680103;
            8'd16:  rom_out = 23'd2725464;
            8'd17:  rom_out = 23'd1024112;
            8'd18:  rom_out = 23'd7300517;
            8'd19:  rom_out = 23'd3585928;
            8'd20:  rom_out = 23'd7830929;
            8'd21:  rom_out = 23'd7260833;
            8'd22:  rom_out = 23'd2619752;
            8'd23:  rom_out = 23'd6271868;
            8'd24:  rom_out = 23'd6262231;
            8'd25:  rom_out = 23'd4520680;
            8'd26:  rom_out = 23'd6980856;
            8'd27:  rom_out = 23'd5102745;
            8'd28:  rom_out = 23'd1757237;
            8'd29:  rom_out = 23'd8360995;
            8'd30:  rom_out = 23'd4010497;
            8'd31:  rom_out = 23'd280005;
            8'd32:  rom_out = 23'd2706023;
            8'd33:  rom_out = 23'd95776;
            8'd34:  rom_out = 23'd3077325;
            8'd35:  rom_out = 23'd3530437;
            8'd36:  rom_out = 23'd6718724;
            8'd37:  rom_out = 23'd4788269;
            8'd38:  rom_out = 23'd5842901;
            8'd39:  rom_out = 23'd3915439;
            8'd40:  rom_out = 23'd4519302;
            8'd41:  rom_out = 23'd5336701;
            8'd42:  rom_out = 23'd3574422;
            8'd43:  rom_out = 23'd5512770;
            8'd44:  rom_out = 23'd3539968;
            8'd45:  rom_out = 23'd8079950;
            8'd46:  rom_out = 23'd2348700;
            8'd47:  rom_out = 23'd7841118;
            8'd48:  rom_out = 23'd6681150;
            8'd49:  rom_out = 23'd6736599;
            8'd50:  rom_out = 23'd3505694;
            8'd51:  rom_out = 23'd4558682;
            8'd52:  rom_out = 23'd3507263;
            8'd53:  rom_out = 23'd6239768;
            8'd54:  rom_out = 23'd6779997;
            8'd55:  rom_out = 23'd3699596;
            8'd56:  rom_out = 23'd811944;
            8'd57:  rom_out = 23'd531354;
            8'd58:  rom_out = 23'd954230;
            8'd59:  rom_out = 23'd3881043;
            8'd60:  rom_out = 23'd3900724;
            8'd61:  rom_out = 23'd5823537;
            8'd62:  rom_out = 23'd2071892;
            8'd63:  rom_out = 23'd5582638;
            8'd64:  rom_out = 23'd4450022;
            8'd65:  rom_out = 23'd6851714;
            8'd66:  rom_out = 23'd4702672;
            8'd67:  rom_out = 23'd5339162;
            8'd68:  rom_out = 23'd6927966;
            8'd69:  rom_out = 23'd3475950;
            8'd70:  rom_out = 23'd2176455;
            8'd71:  rom_out = 23'd6795196;
            8'd72:  rom_out = 23'd7122806;
            8'd73:  rom_out = 23'd1939314;
            8'd74:  rom_out = 23'd4296819;
            8'd75:  rom_out = 23'd7380215;
            8'd76:  rom_out = 23'd5190273;
            8'd77:  rom_out = 23'd5223087;
            8'd78:  rom_out = 23'd4747489;
            8'd79:  rom_out = 23'd126922;
            8'd80:  rom_out = 23'd3412210;
            8'd81:  rom_out = 23'd7396998;
            8'd82:  rom_out = 23'd2147896;
            8'd83:  rom_out = 23'd2715295;
            8'd84:  rom_out = 23'd5412772;
            8'd85:  rom_out = 23'd4686924;
            8'd86:  rom_out = 23'd7969390;
            8'd87:  rom_out = 23'd5903370;
            8'd88:  rom_out = 23'd7709315;
            8'd89:  rom_out = 23'd7151892;
            8'd90:  rom_out = 23'd8357436;
            8'd91:  rom_out = 23'd7072248;
            8'd92:  rom_out = 23'd7998430;
            8'd93:  rom_out = 23'd1349076;
            8'd94:  rom_out = 23'd1852771;
            8'd95:  rom_out = 23'd6949987;
            8'd96:  rom_out = 23'd5037034;
            8'd97:  rom_out = 23'd264944;
            8'd98:  rom_out = 23'd508951;
            8'd99:  rom_out = 23'd3097992;
            8'd100: rom_out = 23'd44288;
            8'd101: rom_out = 23'd7280319;
            8'd102: rom_out = 23'd904516;
            8'd103: rom_out = 23'd3958618;
            8'd104: rom_out = 23'd4656075;
            8'd105: rom_out = 23'd8371839;
            8'd106: rom_out = 23'd1653064;
            8'd107: rom_out = 23'd5130689;
            8'd108: rom_out = 23'd2389356;
            8'd109: rom_out = 23'd8169440;
            8'd110: rom_out = 23'd759969;
            8'd111: rom_out = 23'd7063561;
            8'd112: rom_out = 23'd189548;
            8'd113: rom_out = 23'd4827145;
            8'd114: rom_out = 23'd3159746;
            8'd115: rom_out = 23'd6529015;
            8'd116: rom_out = 23'd5971092;
            8'd117: rom_out = 23'd8202977;
            8'd118: rom_out = 23'd1315589;
            8'd119: rom_out = 23'd1341330;
            8'd120: rom_out = 23'd1285669;
            8'd121: rom_out = 23'd6795489;
            8'd122: rom_out = 23'd7567685;
            8'd123: rom_out = 23'd6940675;
            8'd124: rom_out = 23'd5361315;
            8'd125: rom_out = 23'd4499357;
            8'd126: rom_out = 23'd4751448;
            8'd127: rom_out = 23'd3839961;
            8'd128: rom_out = 23'd2091667;
            8'd129: rom_out = 23'd3407706;
            8'd130: rom_out = 23'd2316500;
            8'd131: rom_out = 23'd3817976;
            8'd132: rom_out = 23'd5037939;
            8'd133: rom_out = 23'd2244091;
            8'd134: rom_out = 23'd5933984;
            8'd135: rom_out = 23'd4817955;
            8'd136: rom_out = 23'd266997;
            8'd137: rom_out = 23'd2434439;
            8'd138: rom_out = 23'd7144689;
            8'd139: rom_out = 23'd3513181;
            8'd140: rom_out = 23'd4860065;
            8'd141: rom_out = 23'd4621053;
            8'd142: rom_out = 23'd7183191;
            8'd143: rom_out = 23'd5187039;
            8'd144: rom_out = 23'd900702;
            8'd145: rom_out = 23'd1859098;
            8'd146: rom_out = 23'd909542;
            8'd147: rom_out = 23'd819034;
            8'd148: rom_out = 23'd495491;
            8'd149: rom_out = 23'd6767243;
            8'd150: rom_out = 23'd8337157;
            8'd151: rom_out = 23'd7857917;
            8'd152: rom_out = 23'd7725090;
            8'd153: rom_out = 23'd5257975;
            8'd154: rom_out = 23'd2031748;
            8'd155: rom_out = 23'd3207046;
            8'd156: rom_out = 23'd4823422;
            8'd157: rom_out = 23'd7855319;
            8'd158: rom_out = 23'd7611795;
            8'd159: rom_out = 23'd4784579;
            8'd160: rom_out = 23'd342297;
            8'd161: rom_out = 23'd286988;
            8'd162: rom_out = 23'd5942594;
            8'd163: rom_out = 23'd4108315;
            8'd164: rom_out = 23'd3437287;
            8'd165: rom_out = 23'd5038140;
            8'd166: rom_out = 23'd1735879;
            8'd167: rom_out = 23'd203044;
            8'd168: rom_out = 23'd2842341;
            8'd169: rom_out = 23'd2691481;
            8'd170: rom_out = 23'd5790267;
            8'd171: rom_out = 23'd1265009;
            8'd172: rom_out = 23'd4055324;
            8'd173: rom_out = 23'd1247620;
            8'd174: rom_out = 23'd2486353;
            8'd175: rom_out = 23'd1595974;
            8'd176: rom_out = 23'd4613401;
            8'd177: rom_out = 23'd1250494;
            8'd178: rom_out = 23'd2635921;
            8'd179: rom_out = 23'd4832145;
            8'd180: rom_out = 23'd5386378;
            8'd181: rom_out = 23'd1869119;
            8'd182: rom_out = 23'd1903435;
            8'd183: rom_out = 23'd7329447;
            8'd184: rom_out = 23'd7047359;
            8'd185: rom_out = 23'd1237275;
            8'd186: rom_out = 23'd5062207;
            8'd187: rom_out = 23'd6950192;
            8'd188: rom_out = 23'd7929317;
            8'd189: rom_out = 23'd1312455;
            8'd190: rom_out = 23'd3306115;
            8'd191: rom_out = 23'd6417775;
            8'd192: rom_out = 23'd7100756;
            8'd193: rom_out = 23'd1917081;
            8'd194: rom_out = 23'd5834105;
            8'd195: rom_out = 23'd7005614;
            8'd196: rom_out = 23'd1500165;
            8'd197: rom_out = 23'd777191;
            8'd198: rom_out = 23'd2235880;
            8'd199: rom_out = 23'd3406031;
            8'd200: rom_out = 23'd7838005;
            8'd201: rom_out = 23'd5548557;
            8'd202: rom_out = 23'd6709241;
            8'd203: rom_out = 23'd6533464;
            8'd204: rom_out = 23'd5796124;
            8'd205: rom_out = 23'd4656147;
            8'd206: rom_out = 23'd594136;
            8'd207: rom_out = 23'd4603424;
            8'd208: rom_out = 23'd6366809;
            8'd209: rom_out = 23'd2432395;
            8'd210: rom_out = 23'd2454455;
            8'd211: rom_out = 23'd8215696;
            8'd212: rom_out = 23'd1957272;
            8'd213: rom_out = 23'd3369112;
            8'd214: rom_out = 23'd185531;
            8'd215: rom_out = 23'd7173032;
            8'd216: rom_out = 23'd5196991;
            8'd217: rom_out = 23'd162844;
            8'd218: rom_out = 23'd1616392;
            8'd219: rom_out = 23'd3014001;
            8'd220: rom_out = 23'd810149;
            8'd221: rom_out = 23'd1652634;
            8'd222: rom_out = 23'd4686184;
            8'd223: rom_out = 23'd6581310;
            8'd224: rom_out = 23'd5341501;
            8'd225: rom_out = 23'd3523897;
            8'd226: rom_out = 23'd3866901;
            8'd227: rom_out = 23'd269760;
            8'd228: rom_out = 23'd2213111;
            8'd229: rom_out = 23'd7404533;
            8'd230: rom_out = 23'd1717735;
            8'd231: rom_out = 23'd472078;
            8'd232: rom_out = 23'd7953734;
            8'd233: rom_out = 23'd1723600;
            8'd234: rom_out = 23'd6577327;
            8'd235: rom_out = 23'd1910376;
            8'd236: rom_out = 23'd6712985;
            8'd237: rom_out = 23'd7276084;
            8'd238: rom_out = 23'd8119771;
            8'd239: rom_out = 23'd4546524;
            8'd240: rom_out = 23'd5441381;
            8'd241: rom_out = 23'd6144432;
            8'd242: rom_out = 23'd7959518;
            8'd243: rom_out = 23'd6094090;
            8'd244: rom_out = 23'd183443;
            8'd245: rom_out = 23'd7403526;
            8'd246: rom_out = 23'd1612842;
            8'd247: rom_out = 23'd4834730;
            8'd248: rom_out = 23'd7826001;
            8'd249: rom_out = 23'd3919660;
            8'd250: rom_out = 23'd8332111;
            8'd251: rom_out = 23'd7018208;
            8'd252: rom_out = 23'd3937738;
            8'd253: rom_out = 23'd1400424;
            8'd254: rom_out = 23'd7534263;
            8'd255: rom_out = 23'd1976782;
            default: rom_out = 23'd0;
        endcase
    end

    // Registered output — allows Genus to optimize timing
    // and reduces critical path through the mux tree
    always @(posedge clk) begin
        data <= rom_out;
    end

endmodule

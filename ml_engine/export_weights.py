import torch

state_dict = torch.load("tinyml_weights.pth")

hw = state_dict['hidden_layer.weight']
hb = state_dict['hidden_layer.bias']
ow = state_dict['output_layer.weight']
ob = state_dict['output_layer.bias']

hw_scaled = torch.round(hw * 256).to(torch.int32)
hb_scaled = torch.round(hb * 256).to(torch.int32)
ow_scaled = torch.round(ow * 256).to(torch.int32)
ob_scaled = torch.round(ob * 256).to(torch.int32)


def to_hex_twos_complement(val, bits=16):
    masked_val = val & ((1 << bits) - 1)
    return f"{masked_val:04X}"

def write_mem_file(filename, tensor_data):
    flat_data = tensor_data.flatten().tolist()  
    with open(filename, "w") as f:
        for val in flat_data:
            hex_string = to_hex_twos_complement(val, bits=16)
            f.write(hex_string + "\n")

write_mem_file("hw.mem", hw_scaled)
write_mem_file("hb.mem", hb_scaled)
write_mem_file("ow.mem", ow_scaled)
write_mem_file("ob.mem", ob_scaled)

print("Export complete! Generated 4 .mem files for the Basys3 FPGA.")
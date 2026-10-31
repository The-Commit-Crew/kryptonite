import torch
import torch.nn as nn

class TinyMLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.hidden_layer = nn.Linear(in_features=64, out_features=16)
        self.relu = nn.ReLU()
        self.output_layer = nn.Linear(in_features=16, out_features=10)

    def forward(self, x):
        x = self.hidden_layer(x)
        x = self.relu(x)
        x = self.output_layer(x)
        return x

if __name__ == "__main__":
    model = TinyMLP()
    dummy_input = torch.zeros(32, 64) 
    predictions = model(dummy_input)
    print(f"Total trainable parameters: {sum(p.numel() for p in model.parameters())}")
    print(f"Input shape: {dummy_input.shape}")
    print(f"Output shape: {predictions.shape}")
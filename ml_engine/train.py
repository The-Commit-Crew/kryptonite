import torch
import torch.nn as nn
from model import TinyMLP
from data_setup import get_dataloader

model = TinyMLP()
train_loader = get_dataloader(batch_size=32)
criterion = nn.CrossEntropyLoss()
optimizer = torch.optim.Adam(model.parameters(), lr=0.001)

epochs = 100

for epoch in range(epochs):
    for images, labels in train_loader:
        optimizer.zero_grad()
        outputs = model(images)
        loss = criterion(outputs, labels)
        loss.backward()
        optimizer.step()
    print(f'Epoch [{epoch}/{epochs}] Loss: {loss.item():.4f}')

torch.save(model.state_dict(), "tinyml_weights.pth")
print("Training complete. Weights saved to tinyml_weights.pth")
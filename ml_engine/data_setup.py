import torch
from torch.utils.data import TensorDataset, DataLoader
from sklearn.datasets import load_digits

def get_dataloader(batch_size=32):
    digits = load_digits()
    raw_images = digits.images
    labels = digits.target
    flattened_images = raw_images.reshape(raw_images.shape[0], -1)
    X_tensor = torch.tensor(flattened_images, dtype=torch.float32)
    y_tensor = torch.tensor(labels, dtype=torch.long)
    dataset = TensorDataset(X_tensor, y_tensor)
    dataloader = DataLoader(dataset, batch_size, shuffle=True)
    return dataloader

if __name__ == "__main__":
    test_loader = get_dataloader()
    batch_images, batch_labels = next(iter(test_loader))
    print(f"Batch Images Shape: {batch_images.shape}")
    print(f"Batch Labels Shape: {batch_labels.shape}")
    print(f"First image's raw pixels:\n{batch_images[0]}")
    print(f"First image's correct label: {batch_labels[0]}")

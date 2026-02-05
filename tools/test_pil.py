
import sys
import os
import io
import math

try:
    from PIL import Image, ImageOps
    print("PIL imported successfully")
except ImportError:
    print("PIL not found")
    sys.exit(1)

def preprocess_image(img_path, require_multiple=64, max_side=1024):
    img = Image.open(img_path)
    # 统一 RGB
    if img.mode != "RGB":
        img = img.convert("RGB")
    
    w, h = img.size
    print(f"Original: {w}x{h}")
    
    # 1. 计算限制尺寸（必须是 require_multiple 的倍数且 <= max_side）
    # 向下取整到 multiple 的倍数
    limit_w = (max_side // require_multiple) * require_multiple
    limit_h = (max_side // require_multiple) * require_multiple
    
    # 2. 计算缩放比例，使得缩放后的 w1, h1 能够放入 limit_w, limit_h
    # 这一步是为了保证后续 pad 的时候不会超过 max_side
    scale = min(1.0, limit_w / w, limit_h / h)
    
    if scale < 1.0:
        w1 = int(w * scale)
        h1 = int(h * scale)
        print(f"Resizing to {w1}x{h1} (scale {scale:.4f})")
        img = img.resize((w1, h1), Image.LANCZOS)
    else:
        w1, h1 = w, h
        
    # 3. 计算 Pad 后的目标尺寸 (向上取整到 multiple 的倍数)
    target_w = math.ceil(w1 / require_multiple) * require_multiple
    target_h = math.ceil(h1 / require_multiple) * require_multiple
    
    print(f"Target: {target_w}x{target_h}")
    
    if target_w == w1 and target_h == h1:
        print("No padding needed")
        return img
    
    # 4. Pad
    new_img = Image.new("RGB", (target_w, target_h), (0, 0, 0))
    # 居中粘贴
    paste_x = (target_w - w1) // 2
    paste_y = (target_h - h1) // 2
    new_img.paste(img, (paste_x, paste_y))
    print(f"Padded with offset ({paste_x}, {paste_y})")
    
    return new_img

# Test cases
if __name__ == "__main__":
    # Create dummy image
    dummy = Image.new("RGB", (800, 600), (255, 0, 0))
    dummy.save("test_800_600.png")
    
    print("--- Test 800x600, Max 1024 ---")
    out = preprocess_image("test_800_600.png", 64, 1024)
    assert out.size[0] % 64 == 0
    assert out.size[1] % 64 == 0
    assert out.size[0] <= 1024
    assert out.size[1] <= 1024
    
    dummy2 = Image.new("RGB", (2000, 1000), (0, 255, 0))
    dummy2.save("test_large.png")
    print("\n--- Test 2000x1000, Max 1024 ---")
    out2 = preprocess_image("test_large.png", 64, 1024)
    print(f"Result: {out2.size}")
    assert out2.size[0] <= 1024
    assert out2.size[1] <= 1024
    assert out2.size[0] % 64 == 0
    
    dummy3 = Image.new("RGBA", (1020, 1020), (0, 0, 255, 128))
    dummy3.save("test_rgba.png")
    print("\n--- Test RGBA 1020x1020, Max 1024 ---")
    out3 = preprocess_image("test_rgba.png", 64, 1024)
    print(f"Result: {out3.size}, Mode: {out3.mode}")
    assert out3.mode == "RGB"
    assert out3.size == (1024, 1024)

    # Test irregular max side
    print("\n--- Test 1000x1000, Max 1000 ---")
    dummy4 = Image.new("RGB", (1000, 1000), (255,255,255))
    dummy4.save("test_1000.png")
    # limit should be floor(1000/64)*64 = 960.
    # So image should be resized to fit 960, then padded to 960?
    # 1000 -> resize to 960. pad to 960.
    out4 = preprocess_image("test_1000.png", 64, 1000)
    print(f"Result: {out4.size}")
    assert out4.size[0] <= 1000
    assert out4.size[0] % 64 == 0

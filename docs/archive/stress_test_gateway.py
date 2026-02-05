import asyncio
import httpx
import time
import sys

# 设置并发数
CONCURRENCY = 20
GATEWAY_URL = "http://localhost:8000"

async def send_request(client, idx):
    start_time = time.time()
    try:
        # 使用 sync=true 让 gateway 等待后端完成，这样响应时间更接近真实处理时间
        payload = {
            "prompt": f"test request {idx}",
            "size": "256x256",
            "steps": 1, 
            "sync": True 
        }
        resp = await client.post(f"{GATEWAY_URL}/v1/images/generations", json=payload, timeout=600)
        duration = time.time() - start_time
        status = resp.status_code
        print(f"Req {idx}: status={status}, time={duration:.2f}s")
        return {"status": status, "duration": duration}
    except Exception as e:
        print(f"Req {idx}: failed {e}")
        return {"status": "error", "duration": time.time() - start_time}

async def main():
    print(f"Starting stress test with {CONCURRENCY} concurrent requests...")
    
    # 获取初始 Metrics
    async with httpx.AsyncClient() as client:
        try:
            r = await client.get(f"{GATEWAY_URL}/metrics")
            print("Initial Metrics:", r.json())
        except:
            print("Could not fetch metrics. Is gateway running on localhost:8000?")
            return

    start_all = time.time()
    
    async with httpx.AsyncClient(timeout=600.0) as client:
        tasks = [send_request(client, i) for i in range(CONCURRENCY)]
        results = await asyncio.gather(*tasks)
    
    total_time = time.time() - start_all
    
    print("\n--- Test Finished ---")
    print(f"Total Wall Time: {total_time:.2f}s")
    
    # 统计
    success_count = sum(1 for r in results if r["status"] == 200)
    failed_count = len(results) - success_count
    max_duration = max(r["duration"] for r in results) if results else 0
    avg_duration = sum(r["duration"] for r in results) / len(results) if results else 0
    
    print(f"Success: {success_count}/{CONCURRENCY}")
    print(f"Avg Req Time: {avg_duration:.2f}s")
    print(f"Max Req Time: {max_duration:.2f}s")
    
    # 再次获取 Metrics
    async with httpx.AsyncClient() as client:
        r = await client.get(f"{GATEWAY_URL}/metrics")
        metrics = r.json()
        print("\nFinal Metrics:", metrics)
        
        # 简单验证逻辑
        backends = metrics.get("backends", {})
        backend_count = len(backends)
        if backend_count > 0:
            print(f"\nAnalysis:")
            print(f"Backend Count: {backend_count}")
            print(f"Expected theoretical min total time approx: (20 / {backend_count}) * SingleReqTime")
            print(f"Actual Total Time: {total_time:.2f}s")

if __name__ == "__main__":
    asyncio.run(main())

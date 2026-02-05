import asyncio
import httpx
import time
import sys

GATEWAY_URL = "http://localhost:8000"
NUM_REQUESTS = 10

async def submit_task(client, i):
    prompt = f"Test request {i}"
    print(f"Submitting task {i}...")
    try:
        resp = await client.post(f"{GATEWAY_URL}/v1/images/generations", json={"prompt": prompt})
        resp.raise_for_status()
        data = resp.json()
        print(f"Task {i} submitted, ID: {data['task_id']}")
        return data['task_id']
    except Exception as e:
        print(f"Failed to submit task {i}: {e}")
        return None

async def poll_task(client, task_id):
    start = time.time()
    while True:
        try:
            resp = await client.get(f"{GATEWAY_URL}/v1/tasks/{task_id}")
            resp.raise_for_status()
            data = resp.json()
            status = data['status']
            if status == 'completed':
                print(f"Task {task_id} COMPLETED. Time taken: {time.time() - start:.2f}s")
                # 简单验证结果是否存在
                if "result" in data and data["result"].startswith("data:image/png;base64"):
                    return True
                else:
                    print(f"Task {task_id} completed but result is missing or invalid format")
                    return False
            elif status == 'failed':
                print(f"Task {task_id} FAILED: {data.get('error')}")
                return False
            
            # 等待 polling
            await asyncio.sleep(0.5)
        except Exception as e:
            print(f"Polling error for {task_id}: {e}")
            await asyncio.sleep(1)

async def run_test():
    async with httpx.AsyncClient() as client:
        # 0. Check health
        try:
            resp = await client.get(f"{GATEWAY_URL}/health")
            print("Gateway Health:", resp.json())
        except Exception as e:
            print(f"Gateway not healthy: {e}")
            return

        # 1. Submit all tasks
        tasks_ids = await asyncio.gather(*[submit_task(client, i) for i in range(NUM_REQUESTS)])
        tasks_ids = [tid for tid in tasks_ids if tid]
        
        if not tasks_ids:
            print("No tasks submitted.")
            return

        print(f"Submitted {len(tasks_ids)} tasks. Polling for results...")
        
        # 2. Poll all tasks
        results = await asyncio.gather(*[poll_task(client, tid) for tid in tasks_ids])
        
        success_count = sum(results)
        print(f"\nTest Finished. Success: {success_count}/{len(tasks_ids)}")

if __name__ == "__main__":
    try:
        asyncio.run(run_test())
    except KeyboardInterrupt:
        pass

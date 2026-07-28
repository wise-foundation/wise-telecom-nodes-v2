import type { RpcPool } from './rpc-pool.js';
import type { ReadExec } from './que-walk.js';

const ROTATION_BUDGET = 5;
const SAME_RPC_RETRIES = 2;
const RETRY_BACKOFF_MS = 400;

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Binds the standard retry-then-rotate read executor to a pool. Same
 * semantics as the readWithRotate helpers inlined in the fetch scripts.
 */
export function makeReadWithRotate(
    pool: RpcPool
): ReadExec {
    return async function readWithRotate<T>(
        label: string,
        fn: () => Promise<T>
    ): Promise<T> {
        let lastErr: unknown;
        for (let rotation = 0; rotation <= ROTATION_BUDGET; rotation++) {
            const urlBefore = pool.rpcUrl();
            for (let attempt = 0; attempt < SAME_RPC_RETRIES; attempt++) {
                try {
                    return await fn();
                } catch (e) {
                    lastErr = e;
                    const msg = (e as Error).message?.split('\n')[0] ?? '';
                    if (attempt < SAME_RPC_RETRIES - 1) {
                        console.error(`  [${urlBefore}] retry ${attempt + 1} for ${label}: ${msg}`);
                        await sleep(RETRY_BACKOFF_MS * (attempt + 1));
                    }
                }
            }
            if (rotation < ROTATION_BUDGET) {
                try {
                    await pool.rotate(urlBefore);
                } catch (e) {
                    console.error(`  pool exhausted: ${(e as Error).message}`);
                    throw e;
                }
            }
        }
        throw lastErr;
    };
}

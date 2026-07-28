import {
    createPublicClient,
    http,
    type PublicClient,
    type Chain,
} from 'viem';

const LIVENESS_TIMEOUT_MS = 4000;
const QUEUE_RESET_DELAY_MS = 5000;

export interface RpcPool {
    client: PublicClient;
    label: string;
    rotate(fromUrl: string): Promise<void>;
    rpcUrl(): string;
}

async function probe(
    url: string,
    chain: Chain,
    probeAddress: `0x${string}`
): Promise<boolean> {
    try {
        const c = createPublicClient({
            chain,
            transport: http(url, { timeout: LIVENESS_TIMEOUT_MS, retryCount: 0 }),
        });
        const head = await c.getBlockNumber();
        if (head === 0n) return false;

        const code = await c.getCode({
            address: probeAddress,
            blockNumber: head - 4n,
        });
        return code !== undefined && code.length > 4;
    } catch {
        return false;
    }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function buildRpcPool(
    candidates: string[],
    chain: Chain,
    probeAddress: `0x${string}`,
    label: string
): Promise<RpcPool> {
    let cycleQueue = [...candidates];
    let currentUrl: string | null = null;
    let currentClient: PublicClient | null = null;
    let rotateInFlight: Promise<void> | null = null;
    let cyclesUsed = 0;

    async function pickNext(): Promise<void> {
        while (true) {
            if (cycleQueue.length === 0) {
                cyclesUsed++;
                if (cyclesUsed >= 3) {
                    throw new Error(
                        `[${label}] all RPCs exhausted across 3 full cycles: ${candidates.join(', ')}`
                    );
                }
                console.log(`[${label}] queue empty (cycle ${cyclesUsed}), resetting in ${QUEUE_RESET_DELAY_MS}ms`);
                await sleep(QUEUE_RESET_DELAY_MS);
                cycleQueue = [...candidates];
            }

            const url = cycleQueue.shift()!;
            if (url === currentUrl) continue;

            process.stdout.write(`[${label}] probing ${url} ... `);
            const ok = await probe(url, chain, probeAddress);
            if (ok) {
                console.log('live');
                currentUrl    = url;
                currentClient = createPublicClient({
                    chain,
                    transport: http(url, { batch: false, timeout: 15_000, retryCount: 0 }),
                });
                return;
            }
            console.log('dead');
        }
    }

    await pickNext();

    const pool: RpcPool = {
        get client() {
            if (!currentClient) throw new Error('pool not initialized');
            return currentClient;
        },
        label,
        rpcUrl: () => currentUrl ?? '',
        rotate: async (fromUrl: string) => {
            if (currentUrl !== fromUrl) {
                return;
            }
            if (rotateInFlight) {
                await rotateInFlight;
                return;
            }
            console.log(`[${label}] rotating away from ${fromUrl}`);
            rotateInFlight = pickNext();
            try {
                await rotateInFlight;
            } finally {
                rotateInFlight = null;
            }
        },
    };

    return pool;
}

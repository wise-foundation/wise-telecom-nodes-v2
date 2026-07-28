import { ETHERSCAN_V2_BASE, TRANSFER_TOPIC } from './chain-config.js';

export interface EtherscanLog {
    address: string;
    topics: [string, string, string];
    data: string;
    blockNumber: string;
    transactionHash: string;
}

interface EtherscanResponse<T> {
    status: string;
    message: string;
    result: T;
}

const PAGE_SIZE = 1000;
const PAGE_DELAY_MS = 250;

function sleep(ms: number): Promise<void> {
    return new Promise((r) => setTimeout(r, ms));
}

export async function fetchAllTransferLogs(
    chainId: number,
    vaultAddress: string,
    apiKey: string
): Promise<EtherscanLog[]> {
    // Etherscan caps page x offset at 10_000 results per block window, so
    // paging with page=2,3,... breaks once a vault accumulates more than
    // 10k transfers. Instead every request uses page=1 and the window
    // advances via fromBlock: a full page is trimmed back to the last
    // COMPLETE block and the next window restarts at the boundary block,
    // re-fetching it in full - no loss, no duplicates, any log count.
    const all: EtherscanLog[] = [];
    let fromBlock = 0n;

    while (true) {
        const url = new URL(ETHERSCAN_V2_BASE);
        url.searchParams.set('chainid', String(chainId));
        url.searchParams.set('module', 'logs');
        url.searchParams.set('action', 'getLogs');
        url.searchParams.set('address', vaultAddress);
        url.searchParams.set('topic0', TRANSFER_TOPIC);
        url.searchParams.set('fromBlock', fromBlock.toString());
        url.searchParams.set('toBlock', 'latest');
        url.searchParams.set('page', '1');
        url.searchParams.set('offset', String(PAGE_SIZE));
        url.searchParams.set('apikey', apiKey);

        const res = await fetch(url);
        const json = (await res.json()) as EtherscanResponse<EtherscanLog[] | string>;

        if (json.message === 'No records found') {
            break;
        }

        if (json.status !== '1') {
            throw new Error(
                `Etherscan getLogs failed (chain=${chainId}, vault=${vaultAddress}, fromBlock=${fromBlock}): ${JSON.stringify(json)}`
            );
        }

        const rows = (json.result ?? []) as EtherscanLog[];

        if (rows.length < PAGE_SIZE) {
            all.push(...rows);
            break;
        }

        const firstBlock = BigInt(rows[0].blockNumber);
        const lastBlock  = BigInt(rows[rows.length - 1].blockNumber);

        if (firstBlock === lastBlock) {
            throw new Error(
                `Etherscan getLogs: block ${lastBlock} alone fills a full page (${PAGE_SIZE} logs); ` +
                `completeness cannot be guaranteed for chain=${chainId}, vault=${vaultAddress}`
            );
        } else {
            all.push(
                ...rows.filter((r) => BigInt(r.blockNumber) < lastBlock)
            );
            fromBlock = lastBlock;
        }

        await sleep(PAGE_DELAY_MS);
    }

    return all;
}

export function extractToAddresses(logs: EtherscanLog[]): string[] {
    const set = new Set<string>();

    for (const log of logs) {
        const toTopic = log.topics[2];
        if (!toTopic) continue;
        const addr = ('0x' + toTopic.slice(-40)).toLowerCase();
        set.add(addr);
    }

    set.delete('0x0000000000000000000000000000000000000000');
    return [...set];
}

export interface SourceCodeResult {
    SourceCode: string;
    ContractName: string;
    CompilerVersion: string;
    OptimizationUsed: string;
    Runs: string;
    EVMVersion: string;
    ConstructorArguments: string;
    ABI: string;
}

export async function fetchSourceCode(
    chainId: number,
    address: string,
    apiKey: string
): Promise<SourceCodeResult> {
    const url = new URL(ETHERSCAN_V2_BASE);
    url.searchParams.set('chainid', String(chainId));
    url.searchParams.set('module', 'contract');
    url.searchParams.set('action', 'getsourcecode');
    url.searchParams.set('address', address);
    url.searchParams.set('apikey', apiKey);

    let lastErr: unknown;
    for (let attempt = 0; attempt < 4; attempt++) {
        try {
            if (attempt > 0) await sleep(500 * attempt);
            const res = await fetch(url);
            const json = (await res.json()) as EtherscanResponse<SourceCodeResult[] | string>;

            if (
                json.status !== '1' &&
                typeof json.result === 'string' &&
                json.result.includes('rate limit')
            ) {
                lastErr = new Error(`rate-limited: ${json.result}`);
                continue;
            }

            if (json.status !== '1') {
                throw new Error(
                    `Etherscan getsourcecode failed (chain=${chainId}, addr=${address}): ${JSON.stringify(json)}`
                );
            }

            const r = (json.result as SourceCodeResult[])[0];
            if (!r) {
                throw new Error(`No source code returned for ${address}`);
            }
            return r;
        } catch (e) {
            lastErr = e;
        }
    }
    throw lastErr;
}

import {NativeModules} from 'react-native';

type NativeDiagnostics = {
    reportRecentLogs: (
        reason: string,
    ) => Promise<{sent: boolean; events: number}>;
};

const native = (NativeModules as {Diagnostics?: NativeDiagnostics}).Diagnostics;

        /**
         * Typed JS facade over the `Diagnostics` native module.
         *
         * Unlike the other bridges, this one NEVER throws or rejects — reporting an
         * error must not become a second error. A missing native module or a failed
         * upload both collapse to a silent no-op.
         *
         * Call flow:
         *
         *   reportRecentLogs(reason)   ← fire-and-forget from catch blocks
         *       │
         *       ├── native undefined → resolve immediately (no-op)
         *       └── native.reportRecentLogs(reason)
         *               ├── resolves → done (result intentionally unused)
         *               └── rejects  → swallowed
         */
        export const DiagnosticsBridge = {
            isAvailable: native !== undefined,

            async reportRecentLogs(reason: string): Promise<void> {
                if (!native) {
                    return;
                }
                try {
                    await native.reportRecentLogs(reason);
                } catch {
                    // Swallowed by design — see module doc.
                }
            },
        };

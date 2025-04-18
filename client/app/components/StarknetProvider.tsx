"use client";

import { sepolia, mainnet, Chain } from "@starknet-react/chains";
import { StarknetConfig, voyager, jsonRpcProvider } from "@starknet-react/core";
import { constants } from "starknet";
import { ControllerConnector } from "@cartridge/connector";
import { DojoSdkProvider } from "@dojoengine/sdk/react";
import { init } from "@dojoengine/sdk";
import { SchemaType } from "../dojo/typescript/models.gen";
import { setupWorld } from "../dojo/typescript/contracts.gen";
import { dojoConfig } from "../dojo/dojo.config";
import { SessionPolicies } from "@cartridge/controller";
import SessionConnector from "@cartridge/connector/session";
import { useAsync, useMountEffect } from "@react-hookz/web";
import { getContractByName } from "@dojoengine/core";
import manifest from "../dojo/manifest_dev.json";

const startContract = getContractByName(manifest, "engine", "start")?.address;

const policies: SessionPolicies = {
  contracts: {
    [startContract]: {
      methods: [
        {
          name: "start",
          entrypoint: "start",
        },
        {
          name: "start_private",
          entrypoint: "start_private",
        },
        {
          name: "join",
          entrypoint: "join",
        },
      ],
    },
  },
}

const cartridgeConnector = new ControllerConnector({
  policies,
  chains: [
    {
      rpcUrl:
        process.env.NEXT_PUBLIC_RPC_SEPOLIA ??
        "https://api.cartridge.gg/x/starknet/sepolia",
    },
    {
      rpcUrl:
        process.env.NEXT_PUBLIC_RPC_MAINNET ??
        "https://api.cartridge.gg/x/starknet/mainnet",
    },
  ],
  defaultChainId: constants.StarknetChainId.SN_SEPOLIA,
})

const session = new SessionConnector({
  policies,
  rpc:
    process.env.NEXT_PUBLIC_RPC_SEPOLIA ??
    "https://api.cartridge.gg/x/starknet/sepolia",
  chainId: constants.StarknetChainId.SN_SEPOLIA,
  redirectUrl: typeof window !== "undefined" ? window.location.origin : "",
});

const provider = jsonRpcProvider({
  rpc: (chain: Chain) => {
    switch (chain) {
      case mainnet:
        return { nodeUrl: "https://api.cartridge.gg/x/starknet/mainnet" };
      case sepolia:
      default:
        return { nodeUrl: "https://api.cartridge.gg/x/starknet/sepolia" };
    }
  },
});

export function StarknetProvider({ children }: { children: React.ReactNode }) {
  const [state, actions] = useAsync(
    async () =>
      await init<SchemaType>({
        client: {
          toriiUrl: dojoConfig.toriiUrl,
          relayUrl: dojoConfig.relayUrl,
          worldAddress: dojoConfig.manifest.world.address,
        },
        domain: {
          name: "TICTACTOE",
          version: "1.0",
          chainId: "SN_SEPOLIA",
          revision: "1",
        },
      })
  );

  useMountEffect(actions.execute);

  if (!state.result) return;

  return (
    <DojoSdkProvider
      sdk={state.result}
      dojoConfig={dojoConfig}
      clientFn={setupWorld}
    >
      <StarknetConfig
        autoConnect
        chains={[sepolia]}
        provider={provider}
        connectors={[cartridgeConnector, session]}
        explorer={voyager}
      >
        {children}
      </StarknetConfig>
    </DojoSdkProvider>
  );
}

import {
  ApolloClient,
  ApolloProvider,
  InMemoryCache,
  ReactiveVar,
  Reference,
  TypePolicies,
  TypePolicy,
  makeVar,
} from '@apollo/client';
import { AddressLike } from 'ethers';
import { PropsWithChildren } from 'react';
import { Contracts, isCollateralTokenAddress, isDebtTokenAddress, isPoolAddress } from '../../config';
import {
  CollSurplusPool,
  RedemptionOperations as RedemptionOperationsContract,
  StabilityPoolManager,
  StoragePool,
  TroveManager,
} from '../../generated/types';
import { RedemptionOperations, SystemInfo, TokenFragmentFragment } from '../generated/gql-types';
import { TOKEN_FRAGMENT } from '../queries';
import { CustomApolloProvider_DevMode } from './CustomApolloProvider_dev';
import { useEthers } from './EthersProvider';
// GENERATED IMPORT CODE START - DO NOT EDIT THIS SECTION MANUALLY
import DebtToken_STABLE from './typePolicies/DebtToken_STABLE.policy';
import DebtToken_STOCK_1 from './typePolicies/DebtToken_STOCK_1.policy';
import ERC20_BTC from './typePolicies/ERC20_BTC.policy';
import ERC20_GOV from './typePolicies/ERC20_GOV.policy';
import ERC20_USDT from './typePolicies/ERC20_USDT.policy';
import SwapPairs_BTC from './typePolicies/SwapPairs_BTC.policy';
import SwapPairs_STOCK_1 from './typePolicies/SwapPairs_STOCK_1.policy';
import SwapPairs_USDT from './typePolicies/SwapPairs_USDT.policy';
// GENERATED IMPORT CODE END

const defaultFieldValue = BigInt(0);

export function CustomApolloProvider({ children }: PropsWithChildren<{}>) {
  const {
    provider,
    contracts: {
      debtTokenContracts,
      troveManagerContract,
      swapPairContracts,
      stabilityPoolManagerContract,
      storagePoolContract,
      collateralTokenContracts,
      priceFeedContract,
      collSurplusContract,
    },
    address: borrower,
  } = useEthers();

  if (process.env.NEXT_PUBLIC_CONTRACT_MOCKING === 'enabled') {
    return <CustomApolloProvider_DevMode>{children}</CustomApolloProvider_DevMode>;
  }

  const cacheConfig = getProductionCacheConfig({
    provider,
    borrower,
    debtTokenContracts,
    collateralTokenContracts,
    troveManagerContract,
    stabilityPoolManagerContract,
    swapPairContracts,
    storagePoolContract,
    priceFeedContract,
    collSurplusContract,
  });

  const client = new ApolloClient({
    uri: process.env.NEXT_PUBLIC_GRAPH_ENDPOINT,

    connectToDevTools: process.env.NODE_ENV === 'development',
    cache: new InMemoryCache({
      typePolicies: {
        ...cacheConfig.fields,

        Query: {
          fields: {
            ...cacheConfig.Query.fields,

            swapEvents: {
              // Don't cache separate results based on
              // any of this field's arguments.
              keyArgs: [],
              // Concatenate the incoming list items with
              // the existing list items.
              merge(existing = [], incoming) {
                return [...existing, ...incoming];
              },
              read: (existing) => {
                return existing;
              },
            },

            borrowerHistories: {
              // Don't cache separate results based on
              // any of this field's arguments.
              keyArgs: [],
              // Concatenate the incoming list items with
              // the existing list items.
              merge(existing = [], incoming) {
                return [...existing, ...incoming];
              },
              read: (existing) => {
                return existing;
              },
            },
          },
        },
      },
    }),
  });

  // TODO: Implement periodic Updates
  // useEffect(() => {
  //   if (process.env.NEXT_PUBLIC_CONTRACT_MOCKING !== 'enabled') {
  //     const priceUSDIntervall = setInterval(() => {
  //       if (
  //         isFieldOutdated(SchemaDataFreshnessManager.SwapPairs['0x687E100f79ceD7Cc8b2BD19Eb326a28885F5b371'], 'swapFee')
  //       ) {
  //         console.log('isFieldOutdated');
  //         SchemaDataFreshnessManager.SwapPairs['0x687E100f79ceD7Cc8b2BD19Eb326a28885F5b371'].swapFee.fetch(
  //           swapPairContracts['STOCK_1'],
  //         );
  //       }

  //       // This can be any interval you want but it guarantees data freshness if its not already fresh.
  //     }, 1000 * 5);

  //     return () => {
  //       clearInterval(priceUSDIntervall);
  //     };
  //   }
  //   // eslint-disable-next-line react-hooks/exhaustive-deps
  // }, []);

  return <ApolloProvider client={client}>{children}</ApolloProvider>;
}

const getProductionCacheConfig = ({
  provider,
  borrower,
  debtTokenContracts,
  collateralTokenContracts,
  troveManagerContract,
  stabilityPoolManagerContract,
  swapPairContracts,
  storagePoolContract,
  priceFeedContract,
  collSurplusContract,
}: {
  provider: ReturnType<typeof useEthers>['provider'];
  borrower: AddressLike;
  debtTokenContracts: ReturnType<typeof useEthers>['contracts']['debtTokenContracts'];
  collateralTokenContracts: ReturnType<typeof useEthers>['contracts']['collateralTokenContracts'];
  troveManagerContract: ReturnType<typeof useEthers>['contracts']['troveManagerContract'];
  stabilityPoolManagerContract: ReturnType<typeof useEthers>['contracts']['stabilityPoolManagerContract'];
  swapPairContracts: ReturnType<typeof useEthers>['contracts']['swapPairContracts'];
  storagePoolContract: ReturnType<typeof useEthers>['contracts']['storagePoolContract'];
  priceFeedContract: ReturnType<typeof useEthers>['contracts']['priceFeedContract'];
  collSurplusContract: ReturnType<typeof useEthers>['contracts']['collSurplusContract'];
}): { fields: TypePolicies; Query: TypePolicy } => ({
  fields: {
    Token: {
      fields: {
        priceUSDOracle: {
          read(_, { readField }) {
            const address = readField('address') as Readonly<string>;

            if (address) {
              if (isDebtTokenAddress(address)) {
                if (isFieldOutdated(SchemaDataFreshnessManager.DebtToken[address], 'priceUSDOracle')) {
                  SchemaDataFreshnessManager.DebtToken[address].priceUSDOracle.fetch(priceFeedContract);
                }
                return SchemaDataFreshnessManager.DebtToken[address].priceUSDOracle.value();
              } else if (isCollateralTokenAddress(address)) {
                if (isFieldOutdated(SchemaDataFreshnessManager.ERC20[address], 'priceUSDOracle')) {
                  SchemaDataFreshnessManager.ERC20[address].priceUSDOracle.fetch(priceFeedContract);
                }
                return SchemaDataFreshnessManager.ERC20[address].priceUSDOracle.value();
              }
            }
          },
        },

        borrowingRate: {
          read(_, { readField }) {
            const address = readField('address') as Readonly<string>;
            if (address) {
              if (isDebtTokenAddress(address)) {
                if (isFieldOutdated(SchemaDataFreshnessManager.DebtToken[address], 'borrowingRate')) {
                  SchemaDataFreshnessManager.DebtToken[address].borrowingRate.fetch(troveManagerContract);
                }
                return SchemaDataFreshnessManager.DebtToken[address].borrowingRate.value();
              } else if (isCollateralTokenAddress(address)) {
                if (isFieldOutdated(SchemaDataFreshnessManager.ERC20[address], 'borrowingRate')) {
                  SchemaDataFreshnessManager.ERC20[address].borrowingRate.fetch(troveManagerContract);
                }
                return SchemaDataFreshnessManager.ERC20[address].borrowingRate.value();
              }
            }
          },
        },

        decimals: {
          read(_, { readField }) {
            const address = readField('address') as Readonly<string>;

            if (address) {
              if (isDebtTokenAddress(address)) {
                if (isFieldOutdated(SchemaDataFreshnessManager.DebtToken[address], 'decimals')) {
                  SchemaDataFreshnessManager.DebtToken[address].decimals.fetch(debtTokenContracts[address]);
                }
                return SchemaDataFreshnessManager.DebtToken[address].decimals.value();
              } else if (isCollateralTokenAddress(address)) {
                if (isFieldOutdated(SchemaDataFreshnessManager.ERC20[address], 'decimals')) {
                  SchemaDataFreshnessManager.ERC20[address].decimals.fetch(collateralTokenContracts[address]);
                }
                return SchemaDataFreshnessManager.ERC20[address].decimals.value();
              }
            }
          },
        },
      },
    },

    DebtTokenMeta: {
      fields: {
        walletAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isDebtTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.DebtToken[tokenData.address], 'walletAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.DebtToken[tokenData.address].walletAmount.fetch(
                  debtTokenContracts[tokenData.address],
                  borrower,
                );
              }

              return SchemaDataFreshnessManager.DebtToken[tokenData.address].walletAmount.value();
            }
          },
        },

        troveMintedAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isDebtTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.DebtToken[tokenData.address], 'troveMintedAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.DebtToken[tokenData.address].troveMintedAmount.fetch({
                  troveManagerContract,
                  borrower,
                });
              }
              return SchemaDataFreshnessManager.DebtToken[tokenData.address].troveMintedAmount.value();
            }
          },
        },

        troveDebtAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isDebtTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.DebtToken[tokenData.address], 'troveDebtAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.DebtToken[tokenData.address].troveDebtAmount.fetch({
                  troveManagerContract,
                  borrower,
                });
              }
              return SchemaDataFreshnessManager.DebtToken[tokenData.address].troveDebtAmount.value();
            }
          },
        },

        troveRepableDebtAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isDebtTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.DebtToken[tokenData.address], 'troveRepableDebtAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.DebtToken[tokenData.address].troveRepableDebtAmount.fetch({
                  troveManagerContract,
                  borrower,
                });
              }
              return SchemaDataFreshnessManager.DebtToken[tokenData.address].troveRepableDebtAmount.value();
            }
          },
        },

        providedStability: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isDebtTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.DebtToken[tokenData.address], 'providedStability') &&
                borrower
              ) {
                SchemaDataFreshnessManager.DebtToken[tokenData.address].providedStability.fetch({
                  stabilityPoolManagerContract,
                  depositor: borrower,
                });
              }
              return SchemaDataFreshnessManager.DebtToken[tokenData.address].providedStability.value();
            }
          },
        },

        compoundedDeposit: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isDebtTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.DebtToken[tokenData.address], 'compoundedDeposit') &&
                borrower
              ) {
                SchemaDataFreshnessManager.DebtToken[tokenData.address].compoundedDeposit.fetch({
                  stabilityPoolManagerContract,
                  depositor: borrower,
                });
              }

              return SchemaDataFreshnessManager.DebtToken[tokenData.address].compoundedDeposit.value();
            }
          },
        },
      },
    },

    CollateralTokenMeta: {
      fields: {
        walletAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isCollateralTokenAddress(tokenData.address)) {
              if (isFieldOutdated(SchemaDataFreshnessManager.ERC20[tokenData.address], 'walletAmount') && borrower) {
                SchemaDataFreshnessManager.ERC20[tokenData.address].walletAmount.fetch(
                  collateralTokenContracts[tokenData.address],
                  borrower,
                );
              }

              return SchemaDataFreshnessManager.ERC20[tokenData.address].walletAmount.value();
            }
          },
        },

        troveLockedAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isCollateralTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.ERC20[tokenData.address], 'troveLockedAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.ERC20[tokenData.address].troveLockedAmount.fetch({
                  troveManagerContract: troveManagerContract,
                  borrower,
                });
              }

              return SchemaDataFreshnessManager.ERC20[tokenData.address].troveLockedAmount.value();
            }
          },
        },

        stabilityGainedAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isCollateralTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.ERC20[tokenData.address], 'stabilityGainedAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.ERC20[tokenData.address].stabilityGainedAmount.fetch({
                  stabilityPoolManagerContract,
                  depositor: borrower,
                });
              }

              return SchemaDataFreshnessManager.ERC20[tokenData.address].stabilityGainedAmount.value();
            }
          },
        },

        collSurplusAmount: {
          read(_, { readField, cache }) {
            const token = readField('token') as Readonly<Reference>;

            const tokenData = cache.readFragment<TokenFragmentFragment>({
              id: token.__ref,
              fragment: TOKEN_FRAGMENT,
            });

            if (tokenData?.address && isCollateralTokenAddress(tokenData.address)) {
              if (
                isFieldOutdated(SchemaDataFreshnessManager.ERC20[tokenData.address], 'collSurplusAmount') &&
                borrower
              ) {
                SchemaDataFreshnessManager.ERC20[tokenData.address].collSurplusAmount.fetch({
                  collSurplusContract,
                  depositor: borrower,
                });
              }

              return SchemaDataFreshnessManager.ERC20[tokenData.address].collSurplusAmount.value();
            }
          },
        },
      },
    },

    Pool: {
      fields: {
        swapFee: {
          read(_, { readField }) {
            const poolAddress = readField('address') as Readonly<string>;

            if (poolAddress && isPoolAddress(poolAddress)) {
              if (isFieldOutdated(SchemaDataFreshnessManager.SwapPairs[poolAddress], 'swapFee')) {
                SchemaDataFreshnessManager.SwapPairs[poolAddress].swapFee.fetch(swapPairContracts[poolAddress]);
              }

              return SchemaDataFreshnessManager.SwapPairs[poolAddress].swapFee.value();
            }
          },
        },

        borrowerAmount: {
          read(_, { readField }) {
            const poolAddress = readField('address') as Readonly<string>;

            if (poolAddress && isPoolAddress(poolAddress)) {
              if (isFieldOutdated(SchemaDataFreshnessManager.SwapPairs[poolAddress], 'borrowerAmount') && borrower) {
                SchemaDataFreshnessManager.SwapPairs[poolAddress].borrowerAmount.fetch(
                  swapPairContracts[poolAddress],
                  borrower,
                );
              }

              return SchemaDataFreshnessManager.SwapPairs[poolAddress].borrowerAmount.value();
            }
          },
        },
      },
    },
  },

  Query: {
    fields: {
      getSystemInfo: {
        read: () => {
          if (isFieldOutdated(SchemaDataFreshnessManager.StoragePool as any, 'totalCollateralRatio')) {
            SchemaDataFreshnessManager.StoragePool.totalCollateralRatio.fetch({ storagePoolContract });
          } else if (isFieldOutdated(SchemaDataFreshnessManager.StoragePool as any, 'recoveryModeActive')) {
            SchemaDataFreshnessManager.StoragePool.recoveryModeActive.fetch({ storagePoolContract });
          }

          return {
            __typename: 'SystemInfo',
            id: 'SystemInfo',
            totalCollateralRatio: SchemaDataFreshnessManager.StoragePool.totalCollateralRatio.value(),
            recoveryModeActive: SchemaDataFreshnessManager.StoragePool.recoveryModeActive.value() as unknown as boolean,
          } as SystemInfo;
        },
      },

      getRedemtionOperations: {
        read: () => {
          if (isFieldOutdated(SchemaDataFreshnessManager.StoragePool as any, 'totalCollateralRatio')) {
            SchemaDataFreshnessManager.StoragePool.totalCollateralRatio.fetch({ storagePoolContract });
          } else if (isFieldOutdated(SchemaDataFreshnessManager.StoragePool as any, 'recoveryModeActive')) {
            SchemaDataFreshnessManager.StoragePool.recoveryModeActive.fetch({ storagePoolContract });
          }

          return {
            __typename: 'RedemptionOperations',
            id: 'RedemptionOperations',
            redemptionRateWithDecay: BigInt(0),
          } as RedemptionOperations;
        },
      },
    },
  },
});

type ContractData<T> = Record<
  string,
  {
    fetch: Function;
    value: ReactiveVar<T>;
    lastFetched: number;
    timeout: number;
  }
>;

// Type that mirros the Contracts object with literal access to the contract addresses
type ContractDataFreshnessManager<T> = {
  [P in keyof T]: T[P] extends Record<string, string>
    ? { [Address in T[P][keyof T[P]]]: ContractData<bigint> }
    : T[P] extends Record<string, object>
      ? ContractData<T[P]['value']>
      : ContractData<bigint>;
};

type ResolvedType<T> = T extends Promise<infer R> ? R : T;
type ContractValue<T> = {
  fetch: Function;
  value: ResolvedType<T>;
  lastFetched: number;
  timeout: number;
};

type TokenAmount = {
  tokenAddress: string;
  amount: bigint;
};

/**
 * This manages the data fetching from the contracts if the data is reused. E.g.: get many debts from the trovemanager isntead of making individual calls.
 */
export const ContractDataFreshnessManager: {
  TroveManager: Record<string, ContractValue<TokenAmount[]>>;
  StabilityPoolManager: Record<string, ContractValue<TokenAmount[]>>;
  StoragePool: Record<
    string,
    ContractValue<{
      isInRecoveryMode: boolean;
      TCR: bigint;
      entireSystemColl: bigint;
      entireSystemDebt: bigint;
    }>
  >;
  CollSurplusPool: Record<string, ContractValue<TokenAmount[]>>;
} = {
  TroveManager: {
    getTroveDebt: {
      fetch: async (troveManagerContract: TroveManager, borrower: AddressLike) => {
        ContractDataFreshnessManager.TroveManager.getTroveDebt.lastFetched = Date.now();
        const troveDebt = await troveManagerContract.getTroveDebt(borrower);

        const tokenAmounts = troveDebt.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.TroveManager.getTroveDebt.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.DebtToken).forEach((tokenAddress) => {
          if (isDebtTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.DebtToken[tokenAddress].troveMintedAmount.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },
    getTroveRepayableDebts: {
      fetch: async (troveManagerContract: TroveManager, borrower: AddressLike) => {
        ContractDataFreshnessManager.TroveManager.getTroveRepayableDebts.lastFetched = Date.now();

        const troveRepayableDebts = await troveManagerContract['getTroveRepayableDebts(address,bool)'](borrower, false);

        const tokenAmounts = troveRepayableDebts.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.TroveManager.getTroveRepayableDebts.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.DebtToken).forEach((tokenAddress) => {
          if (isDebtTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.DebtToken[tokenAddress].troveRepableDebtAmount.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },
    getTroveWithdrawableColls: {
      fetch: async (troveManagerContract: TroveManager, borrower: AddressLike) => {
        ContractDataFreshnessManager.TroveManager.getTroveWithdrawableColls.lastFetched = Date.now();
        const troveColl = await troveManagerContract['getTroveWithdrawableColls(address)'](borrower);

        const tokenAmounts = troveColl.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.TroveManager.getTroveWithdrawableColls.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.ERC20).forEach((tokenAddress) => {
          if (isCollateralTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.ERC20[tokenAddress].troveLockedAmount.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },
  },

  StabilityPoolManager: {
    getDepositorDeposits: {
      fetch: async (stabilityPoolManagerContract: StabilityPoolManager, depositor: AddressLike) => {
        ContractDataFreshnessManager.StabilityPoolManager.getDepositorDeposits.lastFetched = Date.now();
        const depositorDeposits = await stabilityPoolManagerContract.getDepositorDeposits(depositor);

        const tokenAmounts = depositorDeposits.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.StabilityPoolManager.getDepositorDeposits.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.DebtToken).forEach((tokenAddress) => {
          if (isDebtTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.DebtToken[tokenAddress].providedStability.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },

    getDepositorCollGains: {
      fetch: async (stabilityPoolManagerContract: StabilityPoolManager, depositor: AddressLike) => {
        ContractDataFreshnessManager.StabilityPoolManager.getDepositorCollGains.lastFetched = Date.now();
        const depositorCollGains = await stabilityPoolManagerContract.getDepositorCollGains(depositor);

        const tokenAmounts = depositorCollGains.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.StabilityPoolManager.getDepositorCollGains.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.ERC20).forEach((tokenAddress) => {
          if (isCollateralTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.ERC20[tokenAddress].stabilityGainedAmount.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },

    getDepositorCompoundedDeposits: {
      fetch: async (stabilityPoolManagerContract: StabilityPoolManager, depositor: AddressLike) => {
        ContractDataFreshnessManager.StabilityPoolManager.getDepositorCompoundedDeposits.lastFetched = Date.now();
        const depositorCompoundedDeposits =
          await stabilityPoolManagerContract.getDepositorCompoundedDeposits(depositor);

        const tokenAmounts = depositorCompoundedDeposits.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.StabilityPoolManager.getDepositorCompoundedDeposits.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.DebtToken).forEach((tokenAddress) => {
          if (isDebtTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.DebtToken[tokenAddress].compoundedDeposit.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },
  },

  StoragePool: {
    checkRecoveryMode: {
      fetch: async (storagePoolContract: StoragePool) => {
        ContractDataFreshnessManager.StoragePool.checkRecoveryMode.lastFetched = Date.now();
        const [isInRecoveryMode, systemTCR, entireSystemColl, entireSystemDebt] =
          await storagePoolContract['checkRecoveryMode()']();

        ContractDataFreshnessManager.StoragePool.checkRecoveryMode.value = {
          isInRecoveryMode,
          TCR: systemTCR,
          entireSystemColl,
          entireSystemDebt,
        };

        // Update the values of all tokens after fetching.
        SchemaDataFreshnessManager.StoragePool.totalCollateralRatio.fetch();
        SchemaDataFreshnessManager.StoragePool.recoveryModeActive.fetch();
      },
      value: {
        isInRecoveryMode: false,
        TCR: BigInt(0),
        entireSystemColl: BigInt(0),
        entireSystemDebt: BigInt(0),
      } as any,
      lastFetched: 0,
      timeout: 1000 * 2,
    },
  },

  CollSurplusPool: {
    getCollateral: {
      fetch: async (collSurplusContract: CollSurplusPool, depositor: AddressLike) => {
        ContractDataFreshnessManager.CollSurplusPool.getCollateral.lastFetched = Date.now();

        const depositorSurplusCollateral = await collSurplusContract.getCollateral(depositor);

        const tokenAmounts = depositorSurplusCollateral.map(([tokenAddress, amount]) => ({
          tokenAddress,
          amount,
        }));

        ContractDataFreshnessManager.CollSurplusPool.getCollateral.value = tokenAmounts;

        // Update the values of all tokens after fetching.
        Object.values(Contracts.ERC20).forEach((tokenAddress) => {
          if (isCollateralTokenAddress(tokenAddress)) {
            SchemaDataFreshnessManager.ERC20[tokenAddress].collSurplusAmount.fetch();
          }
        });
      },
      value: [],
      lastFetched: 0,
      timeout: 1000 * 2,
    },
  },
};

// FIXME: This is also not perfectly typesafe. The keys are not required.

/**
 * This manages the data, fetching and freshness on each client side field in the schema
 */
export const SchemaDataFreshnessManager: ContractDataFreshnessManager<typeof Contracts> = {
  // GENERATED CODE START - DO NOT EDIT THIS SECTION MANUALLY
  DebtToken: {
    ...DebtToken_STABLE,
    ...DebtToken_STOCK_1,
  },

  ERC20: {
    ...ERC20_BTC,
    ...ERC20_USDT,
    ...ERC20_GOV,
  },

  SwapPairs: {
    ...SwapPairs_BTC,
    ...SwapPairs_USDT,
    ...SwapPairs_STOCK_1,
  },

  // GENERATED CODE END

  StoragePool: {
    totalCollateralRatio: {
      fetch: async (fetchSource?: { storagePoolContract: StoragePool }) => {
        SchemaDataFreshnessManager.StoragePool.totalCollateralRatio.lastFetched = Date.now();

        if (fetchSource) {
          await ContractDataFreshnessManager.StoragePool.checkRecoveryMode.fetch(fetchSource.storagePoolContract);
        }

        const { TCR } = ContractDataFreshnessManager.StoragePool.checkRecoveryMode.value;
        SchemaDataFreshnessManager.StoragePool.totalCollateralRatio.value(TCR);
      },
      value: makeVar(defaultFieldValue),
      lastFetched: 0,
      timeout: 1000 * 2,
    },
    recoveryModeActive: {
      fetch: async (fetchSource?: { storagePoolContract: StoragePool }) => {
        SchemaDataFreshnessManager.StoragePool.recoveryModeActive.lastFetched = Date.now();

        if (fetchSource) {
          await ContractDataFreshnessManager.StoragePool.checkRecoveryMode.fetch(fetchSource.storagePoolContract);
        }

        const { isInRecoveryMode } = ContractDataFreshnessManager.StoragePool.checkRecoveryMode.value;

        SchemaDataFreshnessManager.StoragePool.recoveryModeActive.value(isInRecoveryMode as any);
      },
      value: makeVar(false as any),
      lastFetched: 0,
      timeout: 1000 * 2,
    },
  },
  RedemptionOperations: {
    redemptionRateWithDecay: {
      fetch: async (redemptionOperationsContract: RedemptionOperationsContract) => {
        SchemaDataFreshnessManager.RedemptionOperations.redemptionRateWithDecay.lastFetched = Date.now();

        const redemptionFee = await redemptionOperationsContract.getRedemptionRateWithDecay();

        SchemaDataFreshnessManager.RedemptionOperations.redemptionRateWithDecay.value(redemptionFee);
      },
      value: makeVar(defaultFieldValue),
      lastFetched: 0,
      timeout: 1000 * 2,
    },
  },

  StabilityPoolManager: {},
  SwapOperations: {},
  HintHelpers: {},
  TroveManager: {},
  SortedTroves: {},
  BorrowerOperations: {},
  PriceFeed: {},
  CollSurplus: {},
};

// FIXME: The cache needs to be initialized with the contracts data.

// FIXME: I am too stupid to make this typesafe for now. I must pass the exact Contract Data literally.
function isFieldOutdated(contract: ContractData<any>, field: string) {
  return contract[field].lastFetched < Date.now() - contract[field].timeout;
}

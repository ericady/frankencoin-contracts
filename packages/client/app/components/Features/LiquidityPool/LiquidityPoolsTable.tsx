'use client';

import { useQuery } from '@apollo/client';
import { Table, TableBody, TableCell, TableContainer, TableHead, TableRow } from '@mui/material';
import Typography from '@mui/material/Typography';
import { useEffect, useMemo } from 'react';
import { useEthers } from '../../../context/EthersProvider';
import { GetBorrowerLiquidityPoolsQuery, GetBorrowerLiquidityPoolsQueryVariables } from '../../../generated/gql-types';
import { GET_BORROWER_LIQUIDITY_POOLS } from '../../../queries';
import {
  bigIntStringToFloat,
  dangerouslyConvertBigIntToNumber,
  displayPercentage,
  percentageChange,
  roundCurrency,
  stdFormatter,
} from '../../../utils/math';
import FeatureBox from '../../FeatureBox/FeatureBox';
import DirectionIcon from '../../Icons/DirectionIcon';
import ExchangeIcon from '../../Icons/ExchangeIcon';
import Label from '../../Label/Label';
import HeaderCell from '../../Table/HeaderCell';
import LiquidityPoolsTableLoader from './LiquidityPoolsTableLoader';

type Props = {
  selectedPoolId: string | null;
  setSelectedPoolId: (poolId: string | null) => void;
};

function LiquidityPoolsTable({ selectedPoolId, setSelectedPoolId }: Props) {
  const { address } = useEthers();

  const { data: borrowerPoolsData, loading } = useQuery<
    GetBorrowerLiquidityPoolsQuery,
    GetBorrowerLiquidityPoolsQueryVariables
  >(GET_BORROWER_LIQUIDITY_POOLS, { variables: { borrower: address } });

  // sort for highest borrower investment
  const allPoolsSorted: GetBorrowerLiquidityPoolsQuery['pools'] = useMemo(() => {
    const poolsCopy = [...(borrowerPoolsData?.pools ?? [])];

    return poolsCopy.sort(
      (
        { totalSupply: totalSupplyA, borrowerAmount: borrowerAmountA, liquidity: [liqA1, liqA2] },
        { totalSupply: totalSupplyB, borrowerAmount: borrowerAmountB, liquidity: [liqB1, liqB2] },
      ) =>
        (dangerouslyConvertBigIntToNumber(borrowerAmountB) / bigIntStringToFloat(totalSupplyB)) *
          bigIntStringToFloat(liqA1.totalAmount, liqA1.token.decimals) *
          dangerouslyConvertBigIntToNumber(liqA1.token.priceUSDOracle, 9, 9) +
        (dangerouslyConvertBigIntToNumber(borrowerAmountB) / bigIntStringToFloat(totalSupplyB)) *
          bigIntStringToFloat(liqA2.totalAmount, liqA2.token.decimals) *
          dangerouslyConvertBigIntToNumber(liqA2.token.priceUSDOracle, 9, 9) -
        ((dangerouslyConvertBigIntToNumber(borrowerAmountA) / bigIntStringToFloat(totalSupplyA)) *
          bigIntStringToFloat(liqB1.totalAmount, liqB1.token.decimals) *
          dangerouslyConvertBigIntToNumber(liqB1.token.priceUSDOracle, 9, 9) +
          (dangerouslyConvertBigIntToNumber(borrowerAmountA) / bigIntStringToFloat(totalSupplyA)) *
            bigIntStringToFloat(liqB2.totalAmount, liqB2.token.decimals) *
            dangerouslyConvertBigIntToNumber(liqB2.token.priceUSDOracle, 9, 9)),
    );
  }, [borrowerPoolsData]);

  useEffect(() => {
    // Select first pool by default
    if (allPoolsSorted.length > 0) {
      setSelectedPoolId(allPoolsSorted[0].id);
    }
  }, [allPoolsSorted, setSelectedPoolId]);

  if (!borrowerPoolsData && loading) return <LiquidityPoolsTableLoader />;

  return (
    <FeatureBox title="Pools" noPadding headBorder="full">
      <TableContainer
        sx={{
          borderRight: '1px solid',
          borderLeft: '1px solid',
          borderColor: 'background.paper',
          // // screen - toolbar - feature box - padding top - padding bottom
          // maxHeight: 'calc(100vh - 64px - 54px - 20px - 20px)',
          // overflowY: 'scroll',
        }}
      >
        <Table stickyHeader>
          <TableHead>
            <TableRow>
              <HeaderCell title="Asset" cellProps={{ width: 1 }} />
              <HeaderCell title="" />
              <HeaderCell title="" />
              <HeaderCell title="" cellProps={{ align: 'right' }} />
              <HeaderCell title="" />
              <HeaderCell title="APY" cellProps={{ align: 'right' }} />
              <HeaderCell title="30d Volume" cellProps={{ align: 'right', colSpan: 2 }} />
            </TableRow>
          </TableHead>

          <TableBody>
            {allPoolsSorted.map((pool) => {
              const {
                id,
                liquidity,
                volume30dUSD,
                volume30dUSD30dAgo,
                liquidityDepositAPY,
                borrowerAmount,
                totalSupply,
              } = pool;
              const [tokenA, tokenB] = liquidity;
              const volumeChange = percentageChange(
                bigIntStringToFloat(volume30dUSD.value),
                bigIntStringToFloat(volume30dUSD30dAgo.value),
              );

              return (
                <TableRow
                  key={id}
                  data-testid="apollon-liquidity-pool-table-row"
                  hover={selectedPoolId !== id}
                  selected={selectedPoolId === id}
                  sx={{
                    ':hover': {
                      cursor: selectedPoolId !== id ? 'pointer' : 'default',
                    },
                  }}
                  onClick={() => setSelectedPoolId(pool.id)}
                >
                  <TableCell
                    align="right"
                    sx={{
                      borderLeft: selectedPoolId === id ? '2px solid #33B6FF' : 'none',
                      pl: selectedPoolId === id ? 0 : 2,
                    }}
                  >
                    <Typography fontWeight={400}>
                      {roundCurrency(bigIntStringToFloat(tokenA.totalAmount, tokenA.token.decimals), 5, 5)}
                      <br />
                      <span
                        data-testid="apollon-liquidity-pool-table-row-borrower-amount-token-a"
                        style={{
                          color: '#827F8B',
                          fontSize: '11.7px',
                        }}
                      >
                        {roundCurrency(
                          dangerouslyConvertBigIntToNumber(
                            (borrowerAmount * BigInt(tokenA.totalAmount)) / BigInt(totalSupply),
                            tokenA.token.decimals - 6,
                            6,
                          ),
                          5,
                          5,
                        )}
                      </span>
                    </Typography>
                  </TableCell>

                  <TableCell sx={{ pl: 0, width: '50px', maxWidth: '200px' }} align="right">
                    <Label variant="none">{tokenA.token.symbol}</Label>
                  </TableCell>

                  <TableCell align="center" width={200}>
                    <ExchangeIcon />
                  </TableCell>

                  <TableCell sx={{ pr: 0, width: '50px', maxWidth: '200px' }}>
                    <Typography fontWeight={400}>
                      {roundCurrency(bigIntStringToFloat(tokenB.totalAmount, tokenB.token.decimals), 5, 5)}
                      <br />
                      <span
                        data-testid="apollon-liquidity-pool-table-row-borrower-amount-token-b"
                        style={{
                          color: '#827F8B',
                          fontSize: '11.7px',
                        }}
                      >
                        {roundCurrency(
                          dangerouslyConvertBigIntToNumber(
                            (borrowerAmount * BigInt(tokenB.totalAmount)) / BigInt(totalSupply),
                            tokenB.token.decimals - 6,
                            6,
                          ),
                          5,
                          5,
                        )}
                      </span>
                    </Typography>
                  </TableCell>

                  <TableCell>
                    <Label variant="none">{tokenB.token.symbol}</Label>
                  </TableCell>
                  <TableCell align="right">{displayPercentage(bigIntStringToFloat(liquidityDepositAPY))}</TableCell>

                  <TableCell align="right" sx={{ pr: 0, pl: 1, width: '50px', maxWidth: '200px' }}>
                    <Typography variant="caption" noWrap>
                      {stdFormatter.format(bigIntStringToFloat(volume30dUSD.value))} $
                    </Typography>
                  </TableCell>
                  <TableCell align="right" width={125}>
                    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                      <Typography
                        sx={{
                          color: volumeChange > 0 ? 'success.main' : 'error.main',
                        }}
                        fontWeight={400}
                      >
                        {displayPercentage(volumeChange, 'positive')}
                      </Typography>
                      <DirectionIcon showIncrease={volumeChange > 0} />
                    </div>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </TableContainer>
    </FeatureBox>
  );
}

export default LiquidityPoolsTable;

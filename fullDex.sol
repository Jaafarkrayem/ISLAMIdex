// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

pragma solidity 0.8.19;

contract TokenOrderBook {
    struct Order {
        address trader;
        uint256 amount;
        uint256 executed;
        address currency;
        uint256 price;
        uint256 stopPrice;
        bool isBuy;
        bool isLimit;
        bool isStop;
    }

    struct StopOrder {
        address trader;
        uint256 amount;
        uint256 stopPrice;
        bool buy;
        bool executed;
    }

    struct MarketOrder {
        address trader;
        uint256 amount;
    }

    mapping(bytes32 => Order[]) public buyLimitOrders;
    mapping(bytes32 => Order[]) public sellLimitOrders;
    mapping(bytes32 => Order[]) public executedLimitOrders;

    mapping(bytes32 => Order[]) public buyStopOrders;
    mapping(bytes32 => Order[]) public sellStopOrders;
    mapping(bytes32 => Order[]) public executedStopOrders;

    mapping(bytes32 => Order[]) public buyMarketOrders;
    mapping(bytes32 => Order[]) public sellMarketOrders;
    mapping(bytes32 => Order[]) public executedMarketOrders;

    mapping(bytes32 => StopOrder[]) public stopLimitOrders;

    mapping(bytes32 => Order[]) public remainingSellMarketOrders;

    mapping(bytes32 => Order[]) public stopOrders;

    mapping(bytes32 => Order[]) public executedOrders;

    mapping(bytes32 => Order[]) public remainingBuyMarketOrders;

    //mapping(bytes32 => MarketOrder[]) public marketOrders;
    mapping(address => mapping(uint256 => uint256)) public dailyVolumes;

    function placeLimitBuyOrder(
        address token,
        uint256 amount,
        address currency,
        uint256 price
    ) public {
        bytes32 tokenHash = getTokenHash(token);
        buyLimitOrders[tokenHash].push(
            Order(msg.sender, amount, 0, currency, price, 0, true, true, false)
        );

        // Transfer currency to contract
        IERC20(currency).transferFrom(
            msg.sender,
            address(this),
            amount * price
        );
    }

    function placeLimitSellOrder(address token, uint256 amount, address currency, uint256 price) public {
    bytes32 tokenHash = getTokenHash(token);
    uint256 sellIndex = sellLimitOrders[tokenHash].length;
    sellLimitOrders[tokenHash].push(
        Order(msg.sender, amount, 0, currency, price,0, false, true, false)
    );

    uint256 remainingAmount = amount;

    for (uint256 i = 0; i < buyLimitOrders[tokenHash].length && remainingAmount > 0; ) {
        Order storage buyOrder = buyLimitOrders[tokenHash][i];
        if (buyOrder.price >= price) {
            uint256 executionAmount = min(buyOrder.amount, remainingAmount);
            buyOrder.amount -= executionAmount;
            remainingAmount -= executionAmount;
            if (buyOrder.amount == 0) {
                removeBuyIndex(tokenHash, i);
            }
            executedOrders[tokenHash].push(
                Order(
                    buyOrder.trader,
                    executionAmount,
                    0,
                    currency,
                    price,
                    0,
                    true,
                    false,
                    false
                )
            );
            if (remainingAmount == 0) {
                break;
            }
        } else {
            i++;
        }
    }
    if (remainingAmount > 0) {
        sellMarketOrders[tokenHash].push(
            Order(msg.sender, remainingAmount, 0, currency, 0, 0, false, false, false)
        );
    }

    updateDailyVolumes(token, amount);

    //emit LimitSellOrderPlaced(msg.sender, token, amount, currency, price, sellIndex);
}





    function placeBuyMarketOrder(
        address token,
        uint256 amount,
        address currency
    ) public {
        bytes32 tokenHash = getTokenHash(token);
        buyMarketOrders[tokenHash].push(
            Order(msg.sender, amount, 0, currency, 0, 0, true, false, false)
        );

        // Approve transfer of tokens to contract
        IERC20(currency).approve(address(this), amount);

        // Match with existing sell orders
        uint256 sellIndex = 0;
        while (sellIndex < sellLimitOrders[tokenHash].length && amount > 0) {
            uint256 sellAmount = sellLimitOrders[tokenHash][sellIndex].amount;
            uint256 sellPrice = sellLimitOrders[tokenHash][sellIndex].price;
            uint256 tradeAmount = min(amount, sellAmount);
            uint256 totalPrice = tradeAmount * sellPrice;

            // Transfer tokens from seller to buyer
            IERC20(token).transferFrom(
                sellLimitOrders[tokenHash][sellIndex].trader,
                msg.sender,
                tradeAmount
            );

            // Transfer currency from buyer to seller
            IERC20(currency).transferFrom(
                msg.sender,
                sellLimitOrders[tokenHash][sellIndex].trader,
                totalPrice
            );

            amount -= tradeAmount;

            // Update buy limit order amount and remove sell limit order if fully executed
            sellLimitOrders[tokenHash][sellIndex].amount -= tradeAmount;
            if (sellLimitOrders[tokenHash][sellIndex].amount == 0) {
                removeSellLimitOrder(tokenHash, sellIndex);
            }

            // Add executed market order to executed orders
            executedMarketOrders[tokenHash].push(
                Order(msg.sender, tradeAmount, 0, currency, sellPrice,0, true, false, false)
            );
            dailyVolumes[currency][block.timestamp / 1 days] +=
                tradeAmount *
                sellPrice;

            sellIndex++;
        }

        // Add remaining buy market order to remaining orders
        if (amount > 0) {
            buyMarketOrders[tokenHash][buyMarketOrders[tokenHash].length - 1]
                .amount -= amount;
            remainingBuyMarketOrders[tokenHash].push(
                Order(msg.sender, amount, 0, currency, 0,0, true, false, false)
            );
        }
    }

    function placeMarketSellOrder(address token, uint256 amount, address currency) public {
    bytes32 tokenHash = getTokenHash(token);

    uint256 sellIndex = 0;
    while (sellIndex < sellMarketOrders[tokenHash].length && amount > 0) {
        Order storage sellOrder = sellMarketOrders[tokenHash][sellIndex];
        uint256 remainingSellOrderAmount = sellOrder.amount - dailyVolumes[token][sellOrder.price];
        uint256 sellAmount = min(amount, remainingSellOrderAmount);
        uint256 sellOrderValue = sellAmount * sellOrder.price;

        // Update daily volume for the sell order price
        updateDailyVolumes(token, sellOrderValue);

        // Update remaining amount
        amount -= sellAmount;
        sellOrder.amount -= sellAmount;

        // Execute the sell order
        executedOrders[tokenHash].push(Order(msg.sender, amount, sellAmount, currency, sellOrder.price,0, false, false, false));

        // Add remaining sell market order to remaining orders
        if (sellOrder.amount > 0) {
            remainingSellMarketOrders[tokenHash].push(sellOrder);
        }

        // Remove the executed sell market order
        removeSellMarketOrder(tokenHash, sellIndex);

        // Update sell index
        sellIndex++;
    }

    // If there is any remaining amount, add it to the remaining orders
    if (amount > 0) {
        remainingBuyMarketOrders[tokenHash].push(Order(msg.sender, amount, 0, currency, 0,0, false, false, false));
    }
}


    function placeStopBuyOrder(
        address token,
        uint256 amount,
        address currency,
        uint256 stopPrice
    ) public {
        bytes32 tokenHash = getTokenHash(token);
        stopOrders[tokenHash].push(Order(msg.sender, amount, 0, currency, stopPrice,0,false,false,false));

        // Match with existing sell limit orders
        uint256 sellIndex = 0;
        while (sellIndex < sellLimitOrders[tokenHash].length) {
            uint256 sellAmount = sellLimitOrders[tokenHash][sellIndex].amount;
            uint256 sellPrice = sellLimitOrders[tokenHash][sellIndex].price;
            if (sellPrice <= stopPrice && amount > 0) {
                uint256 tradeAmount = min(amount, sellAmount);
                uint256 totalPrice = tradeAmount * sellPrice;

                // Transfer tokens from seller to buyer
                IERC20(token).transferFrom(
                    sellLimitOrders[tokenHash][sellIndex].trader,
                    msg.sender,
                    tradeAmount
                );

                // Transfer currency from buyer to seller
                IERC20(currency).transferFrom(
                    msg.sender,
                    sellLimitOrders[tokenHash][sellIndex].trader,
                    totalPrice
                );

                amount -= tradeAmount;

                // Remove sell limit order if fully executed
                if (
                    sellLimitOrders[tokenHash][sellIndex].amount == tradeAmount
                ) {
                    removeSellLimitOrder(tokenHash, sellIndex);
                } else {
                    sellLimitOrders[tokenHash][sellIndex].amount -= tradeAmount;
                    sellIndex++;
                }
            } else {
                sellIndex++;
            }
        }

        // Add remaining buy stop order to remaining orders
        if (amount > 0) {
            buyStopOrders[tokenHash].push(
                Order(msg.sender, amount, 0, currency, stopPrice,0, true, false, true)
            );
        }
    }

    function placeStopSellOrder(address token, uint256 amount, address currency, uint256 stopPrice) public {
    bytes32 tokenHash = getTokenHash(token);
    require(amount > 0, "Amount must be greater than 0");
    require(stopPrice > 0, "Stop price must be greater than 0");
    
    // Add stop order to list of orders
    stopOrders[tokenHash].push(Order(msg.sender, amount, 0, currency, 0, stopPrice, false, false, true));
    
    // Try to execute any matching buy limit orders
    uint256 buyIndex = 0;
    while (buyIndex < buyLimitOrders[tokenHash].length && amount > 0) {
        Order storage buyOrder = buyLimitOrders[tokenHash][buyIndex];
        if (buyOrder.price >= stopPrice) {
            uint256 orderAmount = min(amount, buyOrder.amount);
            executeLimitOrders(token, tokenHash, currency, buyIndex, stopOrders[tokenHash].length - 1, buyOrder, orderAmount);
            amount -= orderAmount;
        } else {
            buyIndex++;
        }
    }
    
    // If any amount remains, add stop order to list of stop orders
    if (amount > 0) {
        stopLimitOrders[tokenHash].push(StopOrder(msg.sender, amount, stopPrice, false, false));
    }
    
    // Remove any executed stop or limit orders
    removeExecutedOrder(tokenHash, buyIndex);
    //removeExecutedOrder(tokenHash, executedLimitOrders);
}




    function executeMarketOrders(
        address token,
        bytes32 tokenHash,
        address currency,
        uint256 buyIndex,
        Order storage buyOrder,
        uint256 orderAmount
    ) private {
        uint256 sellIndex = 0;
        while (
            sellIndex < sellMarketOrders[tokenHash].length && orderAmount > 0
        ) {
            Order storage sellOrder = sellMarketOrders[tokenHash][sellIndex];
            uint256 tradeAmount = min(orderAmount, sellOrder.amount);

            // Transfer tokens from seller to buyer
            IERC20(token).transferFrom(
                sellOrder.trader,
                buyOrder.trader,
                tradeAmount
            );

            // Transfer currency from buyer to seller
            IERC20(currency).transferFrom(
                buyOrder.trader,
                sellOrder.trader,
                tradeAmount * sellOrder.price
            );

            // Update daily volume for buyer and seller
            dailyVolumes[buyOrder.trader][
                block.timestamp / 1 days
            ] += tradeAmount;
            dailyVolumes[sellOrder.trader][block.timestamp / 1 days] +=
                tradeAmount *
                sellOrder.price;

            // Update buy and sell market order amounts and remove fully executed orders
            if (sellOrder.amount == tradeAmount) {
                removeSellMarketOrder(tokenHash, sellIndex);
            } else {
                sellOrder.amount -= tradeAmount;
            }

            orderAmount -= tradeAmount;
        }

        // Update buy market order amount and move to remaining orders if partially executed
        if (buyOrder.amount > orderAmount) {
            buyOrder.amount -= orderAmount;
            remainingBuyMarketOrders[tokenHash].push(
                Order(buyOrder.trader, orderAmount, 0, currency, 0, 0,true, false, false)
            );
        }
    }

    function executeLimitOrders(
        address token,
        bytes32 tokenHash,
        address currency,
        uint256 buyIndex,
        uint256 sellIndex,
        Order storage limitOrder,
        uint256 amount
    ) internal {
        // Update executed amounts
        limitOrder.executed += amount;

        // Execute limit order
        if (limitOrder.executed == limitOrder.amount) {
            executedLimitOrders[tokenHash].push(
                Order(
                    limitOrder.trader,
                    limitOrder.amount,
                    0,
                    limitOrder.currency,
                    limitOrder.price,
                    0,
                    limitOrder.isBuy,
                    true,
                    false
                )
            );

            // Remove limit order
            removeBuyLimitOrder(tokenHash, buyIndex);
        }

        // Add executed order
        executedOrders[tokenHash].push(
            Order(msg.sender, amount, 0, currency, limitOrder.price,0, false, true, false)
        );

        // Transfer tokens from buyer to seller
        IERC20(token).transferFrom(msg.sender, limitOrder.trader, amount);

        // Transfer currency from seller to buyer
        uint256 totalPrice = amount * limitOrder.price;
        IERC20(currency).transferFrom(
            limitOrder.trader,
            msg.sender,
            totalPrice
        );

        // Update daily volume
        dailyVolumes[msg.sender][block.timestamp / 1 days] += totalPrice;
        dailyVolumes[limitOrder.trader][block.timestamp / 1 days] += totalPrice;
    }

    function executeStopOrders(
        address token,
        bytes32 tokenHash,
        address currency,
        uint256 buyIndex,
        uint256 sellIndex,
        StopOrder storage stopOrder,
        uint256 amount
    ) internal {
        uint256 remainingAmount = amount;
        uint256 i = 0;
        while (
            i < remainingSellMarketOrders[tokenHash].length &&
            remainingAmount > 0
        ) {
            uint256 orderAmount = min(
                remainingAmount,
                remainingSellMarketOrders[tokenHash][i].amount
            );
            executeMarketOrders(
                token,
                tokenHash,
                currency,
                buyIndex,
                //sellIndex,
                remainingSellMarketOrders[tokenHash][i],
                orderAmount
            );
            remainingAmount -= orderAmount;
            i++;
        }

        if (remainingAmount > 0) {
            remainingBuyMarketOrders[tokenHash].push(
                Order(stopOrder.trader, remainingAmount, 0, currency, 0,0, true, false, false)
            );
        }

        stopOrder.executed = true;
        executedStopOrders[tokenHash].push(
    Order(stopOrder.trader, stopOrder.amount, 0, currency, 0, stopOrder.stopPrice, stopOrder.buy, stopOrder.executed, false)
);

        removeSellStopOrder(tokenHash, buyIndex);
    }

    function getTokenHash(address token) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(token));
    }

    function removeSellLimitOrder(bytes32 tokenHash, uint256 index) internal {
        // Move the last element into the deleted slot
        sellLimitOrders[tokenHash][index] = sellLimitOrders[tokenHash][
            sellLimitOrders[tokenHash].length - 1
        ];

        // Remove the last element
        sellLimitOrders[tokenHash].pop();
    }

    function removeBuyLimitOrder(bytes32 tokenHash, uint256 index) internal {
        // Move the last element into the deleted slot
        buyLimitOrders[tokenHash][index] = buyLimitOrders[tokenHash][
            buyLimitOrders[tokenHash].length - 1
        ];

        // Remove the last element
        buyLimitOrders[tokenHash].pop();
    }

    function removeSellMarketOrder(bytes32 tokenHash, uint256 index) internal {
        if (index < sellMarketOrders[tokenHash].length - 1) {
            sellMarketOrders[tokenHash][index] = sellMarketOrders[tokenHash][
                sellMarketOrders[tokenHash].length - 1
            ];
        }
        sellMarketOrders[tokenHash].pop();
    }

    function removeBuyMarketOrder(bytes32 tokenHash, uint256 index) internal {
        if (index < buyMarketOrders[tokenHash].length - 1) {
            buyMarketOrders[tokenHash][index] = buyMarketOrders[tokenHash][
                buyMarketOrders[tokenHash].length - 1
            ];
        }
        buyMarketOrders[tokenHash].pop();
    }

    function removeStopLimitOrder(bytes32 tokenHash, uint256 index) internal {
        if (index < stopLimitOrders[tokenHash].length - 1) {
            stopLimitOrders[tokenHash][index] = stopLimitOrders[tokenHash][
                stopLimitOrders[tokenHash].length - 1
            ];
        }
        stopLimitOrders[tokenHash].pop();
    }

    function removeStopOrder(bytes32 tokenHash, StopOrder storage stopOrder, bool isBuy) internal {
    uint256 index = isBuy ? stopLimitOrders[tokenHash].length - 1 : sellStopOrders[tokenHash].length - 1;
    while (index >= 0) {
        if (isBuy && stopLimitOrders[tokenHash][index].stopPrice == stopOrder.stopPrice) {
            removeStopLimitOrder(tokenHash, index);
            break;
        } else if (!isBuy && sellStopOrders[tokenHash][index].stopPrice == stopOrder.stopPrice) {
            removeSellStopOrder(tokenHash, index);
            break;
        }
        index--;
    }
}

function removeSellStopOrder(bytes32 tokenHash, uint256 index) internal {
    if (index < sellStopOrders[tokenHash].length - 1) {
        sellStopOrders[tokenHash][index] = sellStopOrders[tokenHash][sellStopOrders[tokenHash].length - 1];
    }
    sellStopOrders[tokenHash].pop();
}


    function removeExecutedOrder(bytes32 tokenHash, uint256 index) internal {
        if (index < executedOrders[tokenHash].length - 1) {
            executedOrders[tokenHash][index] = executedOrders[tokenHash][
                executedOrders[tokenHash].length - 1
            ];
        }
        executedOrders[tokenHash].pop();
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function updateDailyVolumes(address token, uint256 amount) internal {
        dailyVolumes[token][block.timestamp / 1 days] += amount;
    }

    function removeBuyIndex(bytes32 tokenHash, uint256 index) internal {
    if (index < buyMarketOrders[tokenHash].length - 1) {
        buyMarketOrders[tokenHash][index] = buyMarketOrders[tokenHash][buyMarketOrders[tokenHash].length - 1];
    }
    buyMarketOrders[tokenHash].pop();
}

}

                /*********************************************************
                    Proudly Developed by MetaIdentity ltd. Copyright 2023
                **********************************************************/

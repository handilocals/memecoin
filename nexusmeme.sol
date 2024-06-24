// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract Nexusmeme is ERC20, AccessControl, KeeperCompatibleInterface, VRFConsumerBase {
    using SafeMath for uint256;

    uint256 private constant _totalSupply = 30 * 10**12 * 10**18; // 30 trillion tokens

    address public immutable devTeamWallet;
    address public immutable liquidityPool;
    address public immutable burnWallet;
    address public immutable usdtTokenAddress;

    uint256 public constant devFee = 1;
    uint256 public constant liquidityFee = 3;
    uint256 public constant burnFee = 1;
    uint256 public constant totalFee = devFee + liquidityFee + burnFee;

    AggregatorV3Interface internal immutable priceFeed;
    uint256 public lastBurnedMcap = 0; 
    uint256 public lastLotteryMcap = 0;
    uint256 public lastLotteryTime = 0;

    mapping(address => bool) private _isExcludedFromFee;
    mapping(address => bool) private _isActiveWallet;
    address[] private _activeWallets;

    bytes32 internal immutable keyHash;
    uint256 internal immutable fee;
    uint256 public randomResult;
    address public recentWinner;

    struct DailyTransaction {
        uint256 amount;
        uint256 lastUpdated;
    }

    mapping(address => DailyTransaction[7]) private _transactionHistory;

    struct LotteryDraw {
        uint256 timestamp;
        address winner;
        uint256 rewardAmount;
        string congratulatoryMessage;
        string marketingMessage;
    }

    LotteryDraw[] public lotteryHistory;

    event LotteryDrawEvent(uint256 indexed drawTimestamp, address indexed winner, uint256 rewardAmount, string congratulatoryMessage, string marketingMessage);
    event WhitelistUpdated(address indexed account, bool isWhitelisted);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 public liquidityLockTimestamp;
    uint256 public constant liquidityLockPeriod = 365 days;

    uint256 public constant sellThreshold = 1000000 * 10**18; // Example threshold
    uint256 public constant fractionalSellAmount = 100000 * 10**18; // Example fractional amount

    bool public whitelistEnabled = true;
    mapping(address => bool) private _whitelist;

    constructor(
        address _devTeamWallet,
        address _liquidityPool,
        address _burnWallet,
        address _priceFeed,
        address _vrfCoordinator,
        address _linkToken,
        bytes32 _keyHash,
        uint256 _fee,
        address _usdtTokenAddress
    ) ERC20("Nexusmeme", "NEXM") VRFConsumerBase(_vrfCoordinator, _linkToken) {
        _mint(msg.sender, _totalSupply);

        devTeamWallet = _devTeamWallet;
        liquidityPool = _liquidityPool;
        burnWallet = _burnWallet;
        priceFeed = AggregatorV3Interface(_priceFeed);
        keyHash = _keyHash;
        fee = _fee;
        usdtTokenAddress = _usdtTokenAddress;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        _isExcludedFromFee[msg.sender] = true;
        _isExcludedFromFee[address(this)] = true;

        addToWhitelist(_devTeamWallet);
        addToWhitelist(_liquidityPool);
        addToWhitelist(_burnWallet);

        lockLiquidity();
    }

    function addToWhitelist(address account) public onlyRole(ADMIN_ROLE) {
        _whitelist[account] = true;
        emit WhitelistUpdated(account, true);
    }

    function removeFromWhitelist(address account) public onlyRole(ADMIN_ROLE) {
        _whitelist[account] = false;
        emit WhitelistUpdated(account, false);
    }

    function setWhitelistEnabled(bool enabled) public onlyRole(ADMIN_ROLE) {
        whitelistEnabled = enabled;
    }

    function lockLiquidity() public onlyRole(ADMIN_ROLE) {
        require(liquidityLockTimestamp == 0, "Liquidity already locked");
        liquidityLockTimestamp = block.timestamp + liquidityLockPeriod;
    }

    function releaseLiquidity() public onlyRole(ADMIN_ROLE) {
        require(block.timestamp >= liquidityLockTimestamp, "Liquidity is still locked");
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        uint256 currentAllowance = allowance(sender, _msgSender());
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        if (whitelistEnabled) {
            require(
                _whitelist[sender] && _whitelist[recipient],
                "Address not whitelisted"
            );
        }

        uint256 transferAmount = amount;
        if (!_isExcludedFromFee[sender] && !_isExcludedFromFee[recipient]) {
            uint256 feeAmount = amount.mul(totalFee).div(100);
            transferAmount = amount.sub(feeAmount);
            uint256 devAmount = feeAmount.mul(devFee).div(totalFee);
            uint256 liquidityAmount = feeAmount.mul(liquidityFee).div(totalFee);
            uint256 burnAmount = feeAmount.mul(burnFee).div(totalFee);

            super._transfer(sender, devTeamWallet, devAmount);
            super._transfer(sender, liquidityPool, liquidityAmount);
            super._transfer(sender, burnWallet, burnAmount);
        }

        super._transfer(sender, recipient, transferAmount);

        if (amount > sellThreshold && sender != liquidityPool) {
            uint256 remainingAmount = amount;
            while (remainingAmount > fractionalSellAmount) {
                super._transfer(sender, recipient, fractionalSellAmount);
                remainingAmount = remainingAmount.sub(fractionalSellAmount);
            }
            super._transfer(sender, recipient, remainingAmount);
        }

        _updateDailyTransaction(sender, amount);
        _updateDailyTransaction(recipient, amount);
        _updateActiveWallets(sender);
        _updateActiveWallets(recipient);
    }

    function _getTokenPriceUSD() internal view returns (uint256) {
        (, int256 price, , , ) = priceFeed.latestRoundData();
        return uint256(price);
    }

    function burnTokensByMcap() public onlyRole(ADMIN_ROLE) {
        uint256 tokenPriceUSD = _getTokenPriceUSD();
        require(tokenPriceUSD > 0, "Token price must be set by oracle");
        uint256 currentMcap = totalSupply().mul(tokenPriceUSD).div(10**18);
        uint256 burnAmount;

        if (currentMcap >= 1 * 10**6 && lastBurnedMcap < 1 * 10**6) {
            burnAmount = 2 * 10**12 * 10**18;
        } else if (currentMcap > lastBurnedMcap) {
            burnAmount = ((currentMcap.sub(lastBurnedMcap)).div(10**6)).mul(10**6 * 10**18);
        }

        if (burnAmount > 0) {
            _burn(msg.sender, burnAmount);  // Use the admin's address to burn tokens
            lastBurnedMcap = currentMcap;
        }
    }

    function _updateDailyTransaction(address account, uint256 amount) internal {
        uint256 dayIndex = (block.timestamp / 1 days) % 7;
        DailyTransaction storage dailyTx = _transactionHistory[account][dayIndex];
        if (dailyTx.lastUpdated < block.timestamp - 1 days) {
            dailyTx.amount = 0;
        }
        dailyTx.amount = dailyTx.amount.add(amount);
        dailyTx.lastUpdated = block.timestamp;
    }

    function _updateActiveWallets(address account) internal {
        if (!_isActiveWallet[account] && _hasBeenActiveForFourDays(account) && _transactionHistory[account][_getCurrentDay()].amount >= _getMinimumTransactionInTokens()) {
            _isActiveWallet[account] = true;
            _activeWallets.push(account);
        }
    }

    function _hasBeenActiveForFourDays(address account) internal view returns (bool) {
        uint256 activeDays = 0;
        for (uint256 i = 0; i < 7; i++) {
            if (_transactionHistory[account][i].amount >= _getMinimumTransactionInTokens()) {
                activeDays = activeDays.add(1);
            }
            if (activeDays >= 4) {
                return true;
            }
        }
        return false;
    }

    function _getMinimumTransactionInTokens() internal view returns (uint256) {
        uint256 tokenPriceUSD = _getTokenPriceUSD();
        return uint256(10 * 10**18).div(tokenPriceUSD);
    }

    function _getCurrentDay() internal view returns (uint256) {
        return (block.timestamp / 1 days) % 7;
    }

    function _checkAndRunLottery() internal {
        uint256 tokenPriceUSD = _getTokenPriceUSD();
        uint256 currentMcap = totalSupply().mul(tokenPriceUSD).div(10**18);

        if (currentMcap >= 1 * 10**6 && block.timestamp >= getNextSunday() && block.timestamp > lastLotteryTime) {
            requestRandomness(keyHash, fee);
        }
    }

    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        randomResult = randomness;
        _runLottery(randomResult);
    }

    function _runLottery(uint256 randomNumber) internal {
        require(_activeWallets.length >= 10000, "Not enough active wallets for lottery");

        uint256 randomIndex = randomNumber % _activeWallets.length;
        address winner = _activeWallets[randomIndex];
        uint256 tokenPriceUSD = _getTokenPriceUSD();
        uint256 rewardUSD = 10 + (randomNumber % 241);
        uint256 rewardTokens = rewardUSD.mul(10**18).div(tokenPriceUSD);

        _mint(winner, rewardTokens);
        recentWinner = winner;

        string memory congratulatoryMessage = string(abi.encodePacked("Congratulations on your amazing win You have just become the lucky winner of this week's Nexusmeme lottery Your dedication and support have paid off, and we are thrilled to reward you with ", uint2str(rewardTokens), " NEXM tokens. Thank you for being an essential part of our community. Keep believing in the power of Nexusmeme"));
        string memory marketingMessage = ("I just won the Nexusmeme lottery Join the Nexusmeme community and stand a chance to win big every week. Hold and trade NEXM tokens to participate. Let's grow together #Nexusmeme #CryptoLottery #CryptoRewards #Blockchain #CryptoCommunity");

        lotteryHistory.push(LotteryDraw(block.timestamp, winner, rewardTokens, congratulatoryMessage, marketingMessage));

        emit LotteryDrawEvent(block.timestamp, winner, rewardTokens, congratulatoryMessage, marketingMessage);
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }

        return string(bstr);
    }

    function getNextSunday() public view returns (uint256) {
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7;
        uint256 nextSunday = block.timestamp + (7 - dayOfWeek) * 1 days;
        return nextSunday;
    }

    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory /* performData */) {
        uint256 tokenPriceUSD = _getTokenPriceUSD();
        uint256 currentMcap = totalSupply().mul(tokenPriceUSD).div(10**18);
        bool isSunday = block.timestamp >= getNextSunday();
        upkeepNeeded = currentMcap >= 1 * 10**6 && isSunday && block.timestamp > lastLotteryTime;
    }

    function performUpkeep(bytes calldata /* performData */) external override {
        _checkAndRunLottery();
    }
}

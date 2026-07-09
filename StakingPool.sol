// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract StakingPool is Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    uint256 public constant REWARD_PERIOD = 60;
    uint256 public constant WITHDRAW_COOLDOWN = 5 minutes;
    uint256 public constant BASIS_POINTS = 10_000;

    uint256 public constant SILVER_THRESHOLD = 100 * 1e18;
    uint256 public constant GOLD_THRESHOLD = 500 * 1e18;
    uint256 public constant DIAMOND_THRESHOLD = 1000 * 1e18;

    uint256 public constant BRONZE_MULTIPLIER = 10_000;
    uint256 public constant SILVER_MULTIPLIER = 12_000;
    uint256 public constant GOLD_MULTIPLIER = 15_000;
    uint256 public constant DIAMOND_MULTIPLIER = 20_000;

    uint256 public constant LOCK_0_MULTIPLIER = 10_000;
    uint256 public constant LOCK_7_MULTIPLIER = 11_000;
    uint256 public constant LOCK_30_MULTIPLIER = 12_000;
    uint256 public constant LOCK_90_MULTIPLIER = 15_000;

    enum Level { Bronze, Silver, Gold, Diamond }

    IERC20 public immutable stakingToken;

    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lastClaimTime;
        uint256 totalRewardsClaimed;
        uint256 lastWithdrawTime;
        uint256 lockPeriod;
        uint256 lockEndTime;
    }

    mapping(address => StakeInfo) private stakes;

    uint256 public minStakeAmount;
    uint256 public rewardRatePerPeriod;

    uint256 public totalUsers;
    uint256 public totalStaked;
    uint256 public totalWithdrawn;
    uint256 public totalRewardsPaid;
    uint256 public stakeOperationsCount;
    uint256 public unstakeOperationsCount;
    uint256 public claimOperationsCount;

    event StakeCreated(address indexed user, uint256 amount, uint256 lockDays);
    event StakeIncreased(address indexed user, uint256 addedAmount, uint256 newTotal);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);
    event RewardClaimed(address indexed user, uint256 amount);
    event SettingsChanged(string paramName, uint256 oldValue, uint256 newValue);

    constructor(
        address _stakingToken,
        uint256 _minStakeAmount,
        uint256 _rewardRatePerPeriod
    ) Ownable(msg.sender) {
        require(_stakingToken != address(0), "StakingPool: zero token address");

        stakingToken = IERC20(_stakingToken);
        minStakeAmount = _minStakeAmount;
        rewardRatePerPeriod = _rewardRatePerPeriod;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function stake(uint256 amount, uint256 lockDays) external nonReentrant whenNotPaused {
        require(amount > 0, "Stake: amount is zero");
        require(amount >= minStakeAmount, "Stake: below minimum");

        StakeInfo storage s = stakes[msg.sender];

        if (s.amount == 0) {
            require(
                lockDays == 0 || lockDays == 7 || lockDays == 30 || lockDays == 90,
                "Stake: invalid lock period"
            );

            s.startTime = block.timestamp;
            s.lastClaimTime = block.timestamp;
            s.lockPeriod = lockDays * 1 days;
            s.lockEndTime = block.timestamp + s.lockPeriod;

            totalUsers += 1;

            emit StakeCreated(msg.sender, amount, lockDays);
        } else {
            _settleReward(msg.sender);

            emit StakeIncreased(msg.sender, amount, s.amount + amount);
        }

        s.amount += amount;
        totalStaked += amount;
        stakeOperationsCount += 1;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        StakeInfo storage s = stakes[msg.sender];

        require(s.amount > 0, "Unstake: no active stake");
        require(amount > 0, "Unstake: amount is zero");
        require(amount <= s.amount, "Unstake: amount exceeds balance");
        require(block.timestamp >= s.lockEndTime, "Unstake: tokens are locked");
        require(
            block.timestamp - s.lastWithdrawTime >= WITHDRAW_COOLDOWN,
            "Unstake: cooldown active"
        );

        _settleReward(msg.sender);

        s.amount -= amount;
        s.lastWithdrawTime = block.timestamp;

        totalStaked -= amount;
        totalWithdrawn += amount;
        unstakeOperationsCount += 1;

        emit Unstaked(msg.sender, amount, block.timestamp);

        if (s.amount == 0) {
            delete stakes[msg.sender];
        }

        stakingToken.safeTransfer(msg.sender, amount);
    }

    function claimReward() external nonReentrant whenNotPaused {
        require(stakes[msg.sender].amount > 0, "Claim: no active stake");
        uint256 pending = calculatePendingReward(msg.sender);
        require(pending > 0, "Claim: nothing to claim");
        _settleReward(msg.sender);
    }

    function _settleReward(address user) internal {
        StakeInfo storage s = stakes[user];

        uint256 periods = (block.timestamp - s.lastClaimTime) / REWARD_PERIOD;
        if (periods == 0) return;

        uint256 reward = _calculateReward(s.amount, periods, s.lockPeriod);

        s.lastClaimTime += periods * REWARD_PERIOD;

        if (reward > 0) {
            s.totalRewardsClaimed += reward;
            totalRewardsPaid += reward;
            claimOperationsCount += 1;

            emit RewardClaimed(user, reward);

            stakingToken.safeTransfer(user, reward);
        }
    }

    function _calculateReward(
        uint256 amount,
        uint256 periods,
        uint256 lockPeriod
    ) internal view returns (uint256) {
        uint256 baseReward = (amount * rewardRatePerPeriod * periods) / BASIS_POINTS;

        uint256 levelMultiplier = _getLevelMultiplier(amount);
        uint256 lockMultiplier = _getLockMultiplier(lockPeriod);

        return (baseReward * levelMultiplier * lockMultiplier) / (BASIS_POINTS * BASIS_POINTS);
    }

    function calculatePendingReward(address user) public view returns (uint256) {
        StakeInfo storage s = stakes[user];
        if (s.amount == 0) return 0;

        uint256 periods = (block.timestamp - s.lastClaimTime) / REWARD_PERIOD;
        if (periods == 0) return 0;

        return _calculateReward(s.amount, periods, s.lockPeriod);
    }

    function _getLevelMultiplier(uint256 amount) internal pure returns (uint256) {
        if (amount >= DIAMOND_THRESHOLD) return DIAMOND_MULTIPLIER;
        if (amount >= GOLD_THRESHOLD) return GOLD_MULTIPLIER;
        if (amount >= SILVER_THRESHOLD) return SILVER_MULTIPLIER;
        return BRONZE_MULTIPLIER;
    }

    function _getLockMultiplier(uint256 lockPeriod) internal pure returns (uint256) {
        if (lockPeriod >= 90 days) return LOCK_90_MULTIPLIER;
        if (lockPeriod >= 30 days) return LOCK_30_MULTIPLIER;
        if (lockPeriod >= 7 days) return LOCK_7_MULTIPLIER;
        return LOCK_0_MULTIPLIER;
    }

    function getUserLevel(address user) public view returns (Level) {
        uint256 amount = stakes[user].amount;
        if (amount >= DIAMOND_THRESHOLD) return Level.Diamond;
        if (amount >= GOLD_THRESHOLD) return Level.Gold;
        if (amount >= SILVER_THRESHOLD) return Level.Silver;
        return Level.Bronze;
    }

    function getMyStakeInfo()
        external
        view
        returns (
            uint256 amount,
            uint256 startTime,
            uint256 lastClaimTime,
            uint256 totalRewardsClaimed,
            uint256 lockEndTime,
            Level level,
            uint256 pendingReward
        )
    {
        StakeInfo storage s = stakes[msg.sender];
        return (
            s.amount,
            s.startTime,
            s.lastClaimTime,
            s.totalRewardsClaimed,
            s.lockEndTime,
            getUserLevel(msg.sender),
            calculatePendingReward(msg.sender)
        );
    }

    function setMinStakeAmount(uint256 newMin) external onlyRole(ADMIN_ROLE) {
        emit SettingsChanged("minStakeAmount", minStakeAmount, newMin);
        minStakeAmount = newMin;
    }

    function setRewardRatePerPeriod(uint256 newRate) external onlyRole(ADMIN_ROLE) {
        emit SettingsChanged("rewardRatePerPeriod", rewardRatePerPeriod, newRate);
        rewardRatePerPeriod = newRate;
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function depositRewards(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Deposit: amount is zero");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function getUserStats(address user)
        external
        view
        onlyRole(AUDITOR_ROLE)
        returns (
            uint256 amount,
            uint256 startTime,
            uint256 lastClaimTime,
            uint256 totalRewardsClaimed,
            uint256 lockEndTime,
            Level level
        )
    {
        StakeInfo storage s = stakes[user];
        return (
            s.amount,
            s.startTime,
            s.lastClaimTime,
            s.totalRewardsClaimed,
            s.lockEndTime,
            getUserLevel(user)
        );
    }

    function getGlobalStats()
        external
        view
        onlyRole(AUDITOR_ROLE)
        returns (
            uint256 _totalUsers,
            uint256 _totalStaked,
            uint256 _totalWithdrawn,
            uint256 _totalRewardsPaid,
            uint256 _stakeOps,
            uint256 _unstakeOps,
            uint256 _claimOps
        )
    {
        return (
            totalUsers,
            totalStaked,
            totalWithdrawn,
            totalRewardsPaid,
            stakeOperationsCount,
            unstakeOperationsCount,
            claimOperationsCount
        );
    }

    function rescueTokens(address token, uint256 amount, address to) external onlyOwner {
        require(token != address(stakingToken), "Rescue: cannot rescue staking token");
        require(to != address(0), "Rescue: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

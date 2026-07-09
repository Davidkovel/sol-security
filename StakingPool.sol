// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Используется OpenZeppelin v5.x — обратите внимание, что Pausable и
// ReentrancyGuard в v5 переехали из папки security/ в utils/.
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title StakingPool
/// @notice Контракт стейкинга ERC20-токенов с ролями, уровнями и блокировкой на срок
contract StakingPool is Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ==========================================================
    // РОЛИ
    // ==========================================================
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    // ==========================================================
    // КОНСТАНТЫ
    // ==========================================================
    uint256 public constant REWARD_PERIOD = 60; // 60 секунд — один "тик" начисления
    uint256 public constant WITHDRAW_COOLDOWN = 5 minutes;
    uint256 public constant BASIS_POINTS = 10_000; // 100.00% = 10000

    // Пороги уровней. ВАЖНО: предполагается токен с 18 децималами.
    uint256 public constant SILVER_THRESHOLD = 100 * 1e18;
    uint256 public constant GOLD_THRESHOLD = 500 * 1e18;
    uint256 public constant DIAMOND_THRESHOLD = 1000 * 1e18;

    // Множители наград по уровням (в базисных пунктах, 10000 = x1.0)
    uint256 public constant BRONZE_MULTIPLIER = 10_000;  // x1.0
    uint256 public constant SILVER_MULTIPLIER = 12_000;  // x1.2
    uint256 public constant GOLD_MULTIPLIER = 15_000;    // x1.5
    uint256 public constant DIAMOND_MULTIPLIER = 20_000; // x2.0

    // Множители наград по сроку блокировки (в базисных пунктах)
    uint256 public constant LOCK_0_MULTIPLIER = 10_000;  // без блокировки, x1.0
    uint256 public constant LOCK_7_MULTIPLIER = 11_000;  // 7 дней, x1.1
    uint256 public constant LOCK_30_MULTIPLIER = 12_000; // 30 дней, x1.2
    uint256 public constant LOCK_90_MULTIPLIER = 15_000; // 90 дней, x1.5

    enum Level { Bronze, Silver, Gold, Diamond }

    // ==========================================================
    // СОСТОЯНИЕ
    // ==========================================================

    /// @notice Токен, который стейкается и которым же выплачивается награда
    IERC20 public immutable stakingToken;

    struct StakeInfo {
        uint256 amount;              // сколько застейкано сейчас
        uint256 startTime;           // когда создан стейк изначально
        uint256 lastClaimTime;       // с какого момента считать новые награды
        uint256 totalRewardsClaimed; // сколько всего наград получено
        uint256 lastWithdrawTime;    // когда был последний вывод (для кулдауна)
        uint256 lockPeriod;          // выбранный срок блокировки в секундах (0/7d/30d/90d)
        uint256 lockEndTime;         // момент, после которого можно выводить
    }

    mapping(address => StakeInfo) private stakes;

    // Параметры, которые может менять ADMIN_ROLE
    uint256 public minStakeAmount;
    uint256 public rewardRatePerPeriod; // в базисных пунктах за один REWARD_PERIOD

    // Глобальная статистика
    uint256 public totalUsers;
    uint256 public totalStaked;
    uint256 public totalWithdrawn;
    uint256 public totalRewardsPaid;
    uint256 public stakeOperationsCount;
    uint256 public unstakeOperationsCount;
    uint256 public claimOperationsCount;

    // ==========================================================
    // СОБЫТИЯ
    // ==========================================================
    event StakeCreated(address indexed user, uint256 amount, uint256 lockDays);
    event StakeIncreased(address indexed user, uint256 addedAmount, uint256 newTotal);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);
    event RewardClaimed(address indexed user, uint256 amount);
    event SettingsChanged(string paramName, uint256 oldValue, uint256 newValue);
    // Paused/Unpaused — из Pausable
    // RoleGranted/RoleRevoked/RoleAdminChanged — из AccessControl

    // ==========================================================
    // КОНСТРУКТОР
    // ==========================================================
    constructor(
        address _stakingToken,
        uint256 _minStakeAmount,
        uint256 _rewardRatePerPeriod
    ) Ownable(msg.sender) {
        require(_stakingToken != address(0), "StakingPool: zero token address");

        stakingToken = IERC20(_stakingToken);
        minStakeAmount = _minStakeAmount;
        rewardRatePerPeriod = _rewardRatePerPeriod;

        // Владелец контракта (Ownable) сразу получает право администрировать роли
        // и становится первым ADMIN_ROLE.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ==========================================================
    // ОСНОВНЫЕ ФУНКЦИИ ПОЛЬЗОВАТЕЛЯ
    // ==========================================================

    /// @notice Внести токены в стейк. Если стейк уже есть — сумма увеличивается.
    /// @param amount сумма токенов к внесению
    /// @param lockDays срок блокировки: 0, 7, 30 или 90 (учитывается только при первом стейке)
    function stake(uint256 amount, uint256 lockDays) external nonReentrant whenNotPaused {
        require(amount > 0, "Stake: amount is zero");
        require(amount >= minStakeAmount, "Stake: below minimum");

        StakeInfo storage s = stakes[msg.sender];

        if (s.amount == 0) {
            // ---- Новый стейк ----
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
            // ---- Довнесение в существующий стейк ----
            // Сначала фиксируем уже накопленную награду по старой сумме/уровню,
            // иначе при увеличении amount старые периоды будут неверно
            // пересчитаны по новому (более высокому) уровню.
            _settleReward(msg.sender);

            emit StakeIncreased(msg.sender, amount, s.amount + amount);
        }

        s.amount += amount;
        totalStaked += amount;
        stakeOperationsCount += 1;

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Вывести часть или весь стейк (после окончания блокировки и кулдауна)
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

        // Фиксируем награду до изменения суммы стейка
        _settleReward(msg.sender);

        s.amount -= amount;
        s.lastWithdrawTime = block.timestamp;

        totalStaked -= amount;
        totalWithdrawn += amount;
        unstakeOperationsCount += 1;

        emit Unstaked(msg.sender, amount, block.timestamp);

        if (s.amount == 0) {
            // Полностью вышел из стейкинга — очищаем структуру, чтобы при
            // следующем stake() сработала ветка "новый стейк" (в том числе
            // можно будет заново выбрать lockDays).
            delete stakes[msg.sender];
        }

        stakingToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Забрать накопленную награду без вывода тела стейка
    function claimReward() external nonReentrant whenNotPaused {
        require(stakes[msg.sender].amount > 0, "Claim: no active stake");
        uint256 pending = calculatePendingReward(msg.sender);
        require(pending > 0, "Claim: nothing to claim");
        _settleReward(msg.sender);
    }

    // ==========================================================
    // ВНУТРЕННЯЯ ЛОГИКА НАЧИСЛЕНИЯ НАГРАД
    // ==========================================================

    /// @dev Считает и выплачивает накопленную награду, сдвигает lastClaimTime
    /// ровно на количество полных периодов (а не на весь прошедший интервал!),
    /// чтобы не терять "хвостик" времени меньше 60 секунд.
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

    /// @dev Формула: базовая ставка * кол-во периодов * множитель_уровня * множитель_блокировки
    function _calculateReward(
        uint256 amount,
        uint256 periods,
        uint256 lockPeriod
    ) internal view returns (uint256) {
        uint256 baseReward = (amount * rewardRatePerPeriod * periods) / BASIS_POINTS;

        uint256 levelMultiplier = _getLevelMultiplier(amount);
        uint256 lockMultiplier = _getLockMultiplier(lockPeriod);

        // Два умножения на базисные пункты подряд => делим на BASIS_POINTS дважды
        return (baseReward * levelMultiplier * lockMultiplier) / (BASIS_POINTS * BASIS_POINTS);
    }

    /// @notice Посмотреть, сколько награды накопилось прямо сейчас (view, без списания)
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

    // ==========================================================
    // ФУНКЦИИ ПОЛЬЗОВАТЕЛЯ (просмотр своих данных)
    // ==========================================================

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

    // ==========================================================
    // ADMIN_ROLE — управление параметрами и паузой
    // ==========================================================

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

    /// @notice Пополнить пул наград токенами (ADMIN_ROLE должен заранее сделать approve)
    function depositRewards(uint256 amount) external onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Deposit: amount is zero");
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ==========================================================
    // AUDITOR_ROLE — просмотр статистики
    // ==========================================================

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

    // ==========================================================
    // OWNABLE — аварийные функции владельца
    // ==========================================================

    /// @notice Вывести случайно застрявшие на контракте посторонние токены.
    /// Токен стейкинга вывести нельзя — это защита пользовательских средств.
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner {
        require(token != address(stakingToken), "Rescue: cannot rescue staking token");
        require(to != address(0), "Rescue: zero recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    // ==========================================================
    // Разрешение конфликта наследования (AccessControl требует override)
    // ==========================================================
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "../interfaces/IUniswapV3Factory.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/ISwapRouter.sol";

import '../libraries/TickMath.sol';

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../common/AccessiblePlusCommon.sol";
import "./LiquidityVaultStorage.sol";
import "hardhat/console.sol";

contract LiquidityVault is LiquidityVaultStorage, AccessiblePlusCommon {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;


    event ExchangedInVault(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountExchangedOut, uint256 totalClaimsAmount);

    event Claimed(uint256 indexed tokenId, uint256 amount, uint256 totalClaimsAmount);

    event MintedInVault(
        address indexed caller,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event WithdrawalInVault(address caller, address tokenAddress, address to, uint256 amount);

    event Initialized(uint256 _totalAllocatedAmount,
        uint256 _claimCounts,
        uint256[] _claimTimes,
        uint256[] _claimAmounts);

    /// @notice Emitted when liquidity is increased for a position NFT
    /// @dev Also emitted when a token is minted
    /// @param tokenId The ID of the token for which liquidity was increased
    /// @param liquidity The amount by which liquidity for the NFT position was increased
    /// @param amount0 The amount of token0 that was paid for the increase in liquidity
    /// @param amount1 The amount of token1 that was paid for the increase in liquidity
    event IncreaseLiquidityInVault(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when liquidity is decreased for a position NFT
    /// @param tokenId The ID of the token for which liquidity was decreased
    /// @param liquidity The amount by which liquidity for the NFT position was decreased
    /// @param amount0 The amount of token0 that was accounted for the decrease in liquidity
    /// @param amount1 The amount of token1 that was accounted for the decrease in liquidity
    event DecreaseLiquidityInVault(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when tokens are collected for a position NFT
    /// @dev The amounts reported may not be exactly equivalent to the amounts transferred, due to rounding behavior
    /// @param tokenId The ID of the token for which underlying tokens were collected
    /// @param amount0 The amount of token0 owed to the position that was collected
    /// @param amount1 The amount of token1 owed to the position that was collected
    event CollectInVault(uint256 indexed tokenId, uint256 amount0, uint256 amount1);


    modifier nonZeroAddress(address _addr) {
        require(_addr != address(0), "Vault: zero address");
        _;
    }

    modifier nonZero(uint256 _value) {
        require(_value > 0, "Vault: zero value");
        _;
    }

    modifier afterSetUniswap() {
        require(
            address(UniswapV3Factory) != address(0)
            && address(NonfungiblePositionManager) != address(0)
            && address(SwapRouter) != address(0)
            && address(WTON) != address(0)
            && address(TOS) != address(0)
            // && address(WETHUSDCPool) != address(0)
            // && address(WTONWETHPool) != address(0)
            // && address(WTONTOSPool) != address(0)
            ,
            "Vault: before setUniswap");
        _;
    }

    ///@dev constructor
    constructor() {
        owner = msg.sender;
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setupRole(ADMIN_ROLE, owner);
        tickIntervalMinimum = 6000;

    }

    ///@dev setBaseInfo function
    ///@param _name Vault's name
    ///@param _token Allocated token address
    ///@param _owner owner address
    function setBaseInfo(
        string memory _name,
        address _token,
        address _owner
        )
        external
        onlyOwner
    {
        //require(bytes(name).length == 0,"already set");
        name = _name;
        token = IERC20(_token);

        if(_owner != owner){
            owner = _owner;
            _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
            _setupRole(ADMIN_ROLE, owner);
        }
    }

    ///@dev setInitialPrice function
    ///@param tosPrice tosPrice
    ///@param tokenPrice tokenPrice
    ///@param initSqrtPrice initSqrtPriceX96
    function setInitialPrice(
        uint256 tosPrice,
        uint256 tokenPrice,
        uint160 initSqrtPrice
        )
        external
        onlyOwner
    {
        initialTosPrice = tosPrice;
        initialTokenPrice = tokenPrice;
        initSqrtPriceX96 = initSqrtPrice;
    }

    ///@dev setTickIntervalMinimum function
    ///@param _interval _interval
    function setTickIntervalMinimum(
        int24 _interval
        )
        external
        onlyOwner
    {
        require(_interval > 0 , "zero _interval");
        tickIntervalMinimum = _interval;
    }

    ///@dev initialization function
    ///@param _totalAllocatedAmount total allocated amount
    ///@param _claimCounts total claim Counts
    ///@param _claimTimes each claimTime
    ///@param _claimAmounts each claimAmount
    function initialize(
        uint256 _totalAllocatedAmount,
        uint256 _claimCounts,
        uint256[] calldata _claimTimes,
        uint256[] calldata _claimAmounts

    ) external onlyOwner afterSetUniswap {

        require(_totalAllocatedAmount <= token.balanceOf(address(this)), "need to input the token");
        totalAllocatedAmount = _totalAllocatedAmount;
        totalClaimCounts = _claimCounts;
        uint256 i = 0;
        for(i = 0; i < _claimCounts; i++) {
            claimTimes.push(_claimTimes[i]);
            //console.log("claimTimes['%s'] : '%s', _claimTimes[i] : '%s'", i, claimTimes[i], _claimTimes[i]);
            claimAmounts.push(_claimAmounts[i]);
            //console.log("claimAmounts['%s'] : '%s', _claimAmounts[i] : '%s'", i, claimTimes[i], _claimTimes[i]);

            // 사용한 금액
            addAmounts.push(0);
        }

        // _setRoleAdmin(CLAIMER_ROLE, CLAIMER_ROLE);
        // _setupRole(CLAIMER_ROLE, owner);
        // revokeRole(ADMIN_ROLE, owner);
    }

    function setUniswapInfo(
        address poolfactory,
        address npm,
        address swapRouter
        )
        external
        onlyOwner
    {
        require(poolfactory != address(0) && poolfactory != address(UniswapV3Factory), "same factory");
        require(npm != address(0) && npm != address(NonfungiblePositionManager), "same npm");
        require(swapRouter != address(0) && swapRouter != address(SwapRouter), "same swapRouter");

        UniswapV3Factory = IUniswapV3Factory(poolfactory);
        NonfungiblePositionManager = INonfungiblePositionManager(npm);
        SwapRouter = ISwapRouter(swapRouter);
    }

    function setPoolInfo(
            address wethUsdcPool,
            address wtonWethPool,
            address wtonTosPool
        )
        external
        onlyOwner
    {
        require(wethUsdcPool != address(0) && wethUsdcPool != address(WETHUSDCPool), "same wethUsdcPool");
        require(wtonWethPool != address(0) && wtonWethPool != address(WTONWETHPool), "same wtonWethPool");
        require(wtonTosPool != address(0) && wtonTosPool != address(WTONTOSPool), "same wtonTosPool");


        WETHUSDCPool = IUniswapV3Pool(wethUsdcPool);
        WTONWETHPool = IUniswapV3Pool(wtonWethPool);
        WTONTOSPool = IUniswapV3Pool(wtonTosPool);

    }

    function setTokens(
            address wton,
            address tos,
            uint24 _fee
        )
        external
        onlyOwner
    {
        require(wton != address(0) && wton != address(WTON), "same wton");
        require(tos != address(0) && tos != address(TOS), "same tos");

        WTON = IERC20(wton);
        TOS = IERC20(tos);
        fee = _fee;
    }


    function changeToken(address _token) external onlyOwner {
        token = IERC20(_token);
    }

    function computePoolAddress(address tokenA, address tokenB, uint24 _fee)
        public view returns (address pool, address token0, address token1)
    {
        bytes32  POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

        address token0 = tokenA;
        address token1 = tokenB;

        if(token0 > token1) {
            token0 = tokenB;
            token1 = tokenA;
        }
        require(token0 < token1);
        address pool = address( uint160(
            uint256(
                keccak256(
                    abi.encodePacked(
                        hex'ff',
                        address(UniswapV3Factory),
                        keccak256(abi.encode(token0, token1, _fee)),
                        POOL_INIT_CODE_HASH
                    )
                )
            ))
        );

        return (pool, token0, token1);
    }

    function clean() external onlyOwner afterSetUniswap {
        totalClaimsAmount = 0;
    }


    function setPool()
        public afterSetUniswap
    {

        address getPool = UniswapV3Factory.getPool(address(TOS), address(token), fee);
        if(getPool == address(0)){
            address _pool = UniswapV3Factory.createPool(address(TOS), address(token), fee);
            require(_pool != address(0), "createPool fail");
            getPool = _pool;
        }
        pool = IUniswapV3Pool(getPool);
        token0Address = pool.token0();
        token1Address = pool.token1();

        if(initSqrtPriceX96 > 0){
            setPoolInitialize(initSqrtPriceX96);
        }
    }

    function setPoolInitialize(uint160 inSqrtPriceX96)
        public nonZeroAddress(address(pool))
    {
        (uint160 sqrtPriceX96,,,,,,) =  pool.slot0();
        if(sqrtPriceX96 == 0){
            pool.initialize(inSqrtPriceX96);
        }
    }

    function currentRound() public view returns (uint256 round) {
        for(uint256 i = totalClaimCounts; i > 0; i--) {
            if(block.timestamp < claimTimes[0]){
                round = 0;
            } else if(block.timestamp < claimTimes[i-1] && i != 0) {
                round = i-1;
            } else if (block.timestamp > claimTimes[totalClaimCounts-1]) {
                round = totalClaimCounts;
            }
        }
    }

    function calculateClaimAmount(uint256 _round) public view returns (uint256 amount) {
        uint256 expectedClaimAmount;
        for(uint256 i = 0; i < _round; i++) {
           expectedClaimAmount = expectedClaimAmount + claimAmounts[i];
        }
        if(_round == 1 ) {
            amount = claimAmounts[0] ;
        } else
        if(totalClaimCounts == _round) {
            amount = totalAllocatedAmount - totalClaimsAmount;
        } else {
            amount = expectedClaimAmount - totalClaimsAmount;
        }
    }

    function getClaimInfo() public view returns (
        uint256 _totalClaimCounts,
        uint256[] memory _claimTimes,
        uint256[] memory _claimAmounts,
        uint256 _totalClaimsAmount,
        uint256[] memory _addAmounts
        ) {

        return (totalClaimCounts, claimTimes, claimAmounts, totalClaimsAmount, addAmounts) ;
    }

    function availableUseAmount(uint256 _round) public view returns (uint256 amount) {
        uint256 expectedClaimAmount;
        for(uint256 i = 0; i < _round; i++) {
           expectedClaimAmount = expectedClaimAmount + claimAmounts[i] + addAmounts[i];
        }
        if(_round == 1 ) {
            amount = claimAmounts[0] - totalClaimsAmount;
        } else if(totalClaimCounts == _round) {
            amount = totalAllocatedAmount - totalClaimsAmount;
        } else {
            amount = expectedClaimAmount - totalClaimsAmount;
        }
    }


    function calculateSqrtPriceX96(uint256 price)
        external
        pure
        returns (uint)
    {
        uint sqrtPriceX96 = sqrt(price) * (2**96);
        return sqrtPriceX96 ;
    }


    function sqrt(uint x) public pure returns (uint y) {
        uint z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function tickSpace() public view returns (int24) {
       return (TickMath.MAX_TICK / int24(fee));
    }

    function tickBaseInfos() public view returns (int24, int24, uint24) {
        int24 minTick = -1 * tickSpace() * int24(fee);
        int24 maxTick = tickSpace() * int24(fee);
        uint24 numTicks = uint24(int24((maxTick - minTick) / int24(fee))) + 1;

        return (minTick, maxTick, numTicks);
    }

    function getSqrtRatioAtTick(int24 tick) public pure returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) public pure returns (int24) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function MIN_SQRT_RATIO() external pure returns (uint160) {
        return TickMath.MIN_SQRT_RATIO;
    }

    function MAX_SQRT_RATIO() external pure returns (uint160) {
        return TickMath.MAX_SQRT_RATIO;
    }

    function approveERC20(address token, address to, uint256 amount)
        public
        nonZeroAddress(token)
        nonZeroAddress(to)
        nonZero(amount)
        returns (bool)
    {
        return IERC20(token).approve(to, amount);
    }

    function checkBalance(uint256 tosBalance, uint256 tokenBalance) public view {
        require(TOS.balanceOf(address(this)) >= tosBalance, "tos is insufficient.");
        require(token.balanceOf(address(this)) >= tokenBalance, "token is insufficient.");
    }

    /*
    function mint(int24 tickLower, int24 tickUpper, uint256)
        external
        nonZeroAddress(address(pool))
        nonZeroAddress(token0Address)
        nonZeroAddress(token1Address)
    {
        require(block.timestamp > claimTimes[0], "Vault: not started yet");
        // console.log("tickLower  %s", uint256(uint24(tickLower)));
        // console.log("tickUpper  %s", uint256(uint24(tickUpper)));


        // console.log("tickIntervalMinimum  %s", uint256(uint24(tickIntervalMinimum)));

        // console.log("tick Interval   %s", uint256(uint24(tickUpper - tickLower)));


        require(tickUpper - tickLower >= tickIntervalMinimum, "Vault: tick interval is less than tickIntervalMinimum");
        require(totalAllocatedAmount > totalClaimsAmount,"Vault: already All get");
        uint256 curRound = currentRound();
        uint256 amount = availableUseAmount(curRound);
        // require(tokenUseAmount <= amount, "exceed to claimable amount");

        require(amount > 0, "claimable token is zero");
        uint256 tokenUseAmount = amount;
        uint256 tosUseAmount =  TOS.balanceOf(address(this));
        require(tosUseAmount > 0, "tos balance is zero");

        console.log("tos  %s", tosUseAmount);
        console.log("token %s", tokenUseAmount);


        nowClaimRound = curRound;

        (,int24 tick,,,,,) =  pool.slot0();

        require(tickLower < tick && tick < tickUpper, "tick is out of range");

        uint256 amount0Desired =  tosUseAmount;
        uint256 amount1Desired =  tokenUseAmount;
        if(token0Address != address(TOS)){
            amount0Desired = tokenUseAmount;
            amount1Desired = tosUseAmount;
        }

        checkBalance(tosUseAmount, tokenUseAmount);

        if(tosUseAmount > TOS.allowance(address(this), address(NonfungiblePositionManager)) ) {
                require(TOS.approve(address(NonfungiblePositionManager),TOS.totalSupply()),"TOS approve fail");
        }

        if(tokenUseAmount > token.allowance(address(this), address(NonfungiblePositionManager)) ) {
            require(token.approve(address(NonfungiblePositionManager),token.totalSupply()),"token approve fail");
        }

        console.logInt(tickLower);
         console.logInt(tickUpper);
        //console.log("tickUpper %s", uint256(int256(tickUpper)));

        uint256 allowanceTOS = TOS.allowance(address(this), address(NonfungiblePositionManager));
        console.log("allowanceTOS %s", allowanceTOS);

        uint256 allowanceTOKEN = token.allowance(address(this), address(NonfungiblePositionManager));
        console.log("allowanceTOKEN %s", allowanceTOKEN);


        int24 _tickLower = tickLower;
        int24 _tickUpper = tickUpper;
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = NonfungiblePositionManager.mint(INonfungiblePositionManager.MintParams(
                token0Address, token1Address, fee, _tickLower, _tickUpper,
                amount0Desired, amount1Desired, 0, 0,
                address(this), block.timestamp + 100000
            )
        );

        console.log("tokenId %s", tokenId);

        if(token0Address != address(TOS)){
            totalClaimsAmount = totalClaimsAmount + amount0;
            emit Claimed(tokenId, amount0, totalClaimsAmount);
        } else {
            totalClaimsAmount = totalClaimsAmount + amount1;
            emit Claimed(tokenId, amount1, totalClaimsAmount);
        }

        emit Minted(msg.sender, tokenId, liquidity, amount0, amount1);
    }
    */
    function mint(int24 tickLower, int24 tickUpper)
        external
    {
        mintToken(tickLower, tickUpper,  TOS.balanceOf(address(this)),  token.balanceOf(address(this))/totalClaimCounts );
    }

    function mintToken(int24 tickLower, int24 tickUpper, uint256 tosUseAmount, uint256 tokenUseAmount)
        public
        nonZeroAddress(address(pool))
        nonZeroAddress(token0Address)
        nonZeroAddress(token1Address)
    {
        require(block.timestamp > claimTimes[0], "Vault: not started yet");
        require(tokenUseAmount > 1 ether, "small token amount");
        require(tickUpper - tickLower >= tickIntervalMinimum, "Vault: tick interval is less than tickIntervalMinimum");
        require(totalAllocatedAmount > totalClaimsAmount,"Vault: already All get");
        uint256 curRound = currentRound();
        uint256 amount = availableUseAmount(curRound);
        // console.log("availableUseAmount  %s", amount);
        // console.log("tokenUseAmount  %s", tokenUseAmount);

        require(tokenUseAmount <= amount, "exceed to claimable amount");
        require(amount > 0, "claimable token is zero");
        //uint256 tokenUseAmount = amount;
        require(tokenUseAmount > 0, "tokenUseAmount is zero");

        uint256 tosBalance =  TOS.balanceOf(address(this));
        require(tosBalance >= tosUseAmount && tosUseAmount > 0, "tos balance is zero");

        //console.log("tos  %s", tosUseAmount);
        //console.log("token %s", tokenUseAmount);

        nowClaimRound = curRound;

        (,int24 tick,,,,,) =  pool.slot0();

        require(tickLower < tick && tick < tickUpper, "tick is out of range");

        uint256 amount0Desired =  tosUseAmount;
        uint256 amount1Desired =  tokenUseAmount;
        if(token0Address != address(TOS)){
            amount0Desired = tokenUseAmount;
            amount1Desired = tosUseAmount;
        }

        //console.log("amount0Desired  %s", amount0Desired);
        //console.log("amount1Desired  %s", amount1Desired);

        checkBalance(tosUseAmount, tokenUseAmount);

        if(tosUseAmount > TOS.allowance(address(this), address(NonfungiblePositionManager)) ) {
                require(TOS.approve(address(NonfungiblePositionManager),TOS.totalSupply()),"TOS approve fail");
        }

        if(tokenUseAmount > token.allowance(address(this), address(NonfungiblePositionManager)) ) {
            require(token.approve(address(NonfungiblePositionManager),token.totalSupply()),"token approve fail");
        }

        //console.logInt(tickLower);
        // console.logInt(tickUpper);
        //console.log("tickUpper %s", uint256(int256(tickUpper)));

        uint256 allowanceTOS = TOS.allowance(address(this), address(NonfungiblePositionManager));
        //console.log("allowanceTOS %s", allowanceTOS);

        uint256 allowanceTOKEN = token.allowance(address(this), address(NonfungiblePositionManager));
        //console.log("allowanceTOKEN %s", allowanceTOKEN);


        int24 _tickLower = tickLower;
        int24 _tickUpper = tickUpper;
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = NonfungiblePositionManager.mint(INonfungiblePositionManager.MintParams(
                token0Address, token1Address, fee, _tickLower, _tickUpper,
                amount0Desired, amount1Desired, 0, 0,
                address(this), block.timestamp + 100000
            )
        );

        require(tokenId > 0, "tokenId is zero");
        tokenIds.push(tokenId);
        //console.log("tokenId %s", tokenId);
        // console.log("amount0 %s", amount0);
        // console.log("amount1 %s", amount1);
        // console.log("token0Address %s", token0Address);
        // console.log("address(TOS) %s", address(TOS));
        if(token0Address != address(TOS)){
            totalClaimsAmount = totalClaimsAmount + amount0;
            emit Claimed(tokenId, amount0, totalClaimsAmount);
        } else {
            totalClaimsAmount = totalClaimsAmount + amount1;
            emit Claimed(tokenId, amount1, totalClaimsAmount);
        }
        // console.log("totalClaimsAmount %s", totalClaimsAmount);
        emit MintedInVault(msg.sender, tokenId, liquidity, amount0, amount1);
    }


    function increaseLiquidity(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 deadline
    )
        external
        nonZeroAddress(address(pool))
        nonZeroAddress(token0Address)
        nonZeroAddress(token1Address)
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(block.timestamp > claimTimes[0], "Vault: not started yet");
        require(totalAllocatedAmount > totalClaimsAmount,"Vault: already All get");
        uint256 curRound = currentRound();
        uint256 amount = availableUseAmount(curRound);

        if(token0Address != address(TOS)){
            require(amount0Desired <= amount, "exceed to claimable amount");
        } else {
            require(amount1Desired <= amount, "exceed to claimable amount");
        }

        nowClaimRound = curRound;

        (
            liquidity,
            amount0,
            amount1
        ) = NonfungiblePositionManager.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams(
                tokenId, amount0Desired, amount1Desired, 0, 0, deadline
            )
        );

        // console.log("tokenId %s", tokenId);
        // console.log("amount0 %s", amount0);
        // console.log("amount1 %s", amount1);
        // console.log("token0Address %s", token0Address);
        // console.log("address(TOS) %s", address(TOS));

        if(token0Address != address(TOS)){
            totalClaimsAmount = totalClaimsAmount + amount0;
            emit Claimed(tokenId, amount0, totalClaimsAmount);
        } else {
            totalClaimsAmount = totalClaimsAmount + amount1;
            emit Claimed(tokenId, amount1, totalClaimsAmount);
        }
        // console.log("totalClaimsAmount %s", totalClaimsAmount);
        emit IncreaseLiquidityInVault(tokenId, liquidity, amount0, amount1);
    }

    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        external
        nonZeroAddress(address(pool))
        nonZeroAddress(token0Address)
        nonZeroAddress(token1Address)
        returns (
            uint256 amount0,
            uint256 amount1
        )
    {
        (
            amount0,
            amount1
        ) = NonfungiblePositionManager.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams(
                tokenId, liquidity, amount0Min, amount1Min, deadline
            )
        );

        if(token0Address == address(token) && amount0 > 0){
            totalClaimsAmount = totalClaimsAmount - amount0;
        } else if (token1Address == address(token) && amount1 > 0) {
            totalClaimsAmount = totalClaimsAmount - amount1;
            emit Claimed(tokenId, amount1, totalClaimsAmount);
        }

        emit DecreaseLiquidityInVault(tokenId, liquidity, amount0, amount1);
    }

    function collect(
        uint256 tokenId,
        uint128 amount0Max,
        uint128 amount1Max
    )
        external returns (uint256 amount0, uint256 amount1)
    {
        (
            amount0,
            amount1
        ) = NonfungiblePositionManager.collect(INonfungiblePositionManager.CollectParams(
                tokenId, address(this), amount0Max, amount1Max
            )
        );

        if(token0Address == address(token) && amount0 > 0){

            totalClaimsAmount = totalClaimsAmount + amount0;
            emit Claimed(tokenId, amount0, totalClaimsAmount);

        } else if(token1Address == address(token) && amount1 > 0) {

            totalClaimsAmount = totalClaimsAmount + amount1;
            emit Claimed(tokenId, amount1, totalClaimsAmount);

        }

        emit CollectInVault(tokenId, amount0, amount1);
    }

    function swap(bool tosToToken, uint256 amountIn, uint256 amountOut, uint160 sqrtPriceLimitX96)
        public
    {
        uint256 amountExchangedOut = 0;
        address tokenIn = address(TOS);
        address tokenOut = address(token);
        if(!tosToToken){
            tokenIn = address(token);
            tokenOut = address(TOS);
        }

        amountExchangedOut = SwapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams(
                tokenIn, tokenOut, fee, address(this), block.timestamp+10000, amountIn, amountOut, sqrtPriceLimitX96
        ));

        if(tosToToken){
            totalClaimsAmount = totalClaimsAmount + amountExchangedOut;
        } else {
            totalClaimsAmount = totalClaimsAmount - amountIn;
        }

        emit ExchangedInVault(tokenIn, tokenOut, amountIn, amountExchangedOut, totalClaimsAmount);
    }

    function withdraw(address _token, address _account, uint256 _amount)
        external
        onlyOwner
    {
        require(totalAllocatedAmount <= totalClaimsAmount, "not closed");
        //require(_token != address(token), "can not withdraw token");
        require(IERC20(_token).balanceOf(address(this)) >= _amount,"Vault: dont have token");
        IERC20(_token).safeTransfer(_account, _amount);

        emit WithdrawalInVault(msg.sender, _token, _account, _amount);
    }

}

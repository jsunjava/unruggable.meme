use debug::PrintTrait;
use openzeppelin::token::erc20::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
use snforge_std::{start_prank, stop_prank, CheatTarget};
use unruggable::exchanges::SupportedExchanges;
use unruggable::exchanges::jediswap_adapter::{
    IJediswapFactoryDispatcher, IJediswapFactoryDispatcherTrait, IJediswapRouterDispatcher,
    IJediswapRouterDispatcherTrait, IJediswapPairDispatcher, IJediswapPairDispatcherTrait,
};
use unruggable::factory::interface::{IFactoryDispatcher, IFactoryDispatcherTrait};
use unruggable::locker::LockPosition;
use unruggable::locker::interface::{ILockManagerDispatcher, ILockManagerDispatcherTrait};
use unruggable::tests::addresses::{JEDI_FACTORY_ADDRESS, JEDI_ROUTER_ADDRESS, ETH_ADDRESS};
use unruggable::tests::fork_tests::utils::{deploy_memecoin_through_factory_with_owner, sort_tokens};
use unruggable::tests::unit_tests::utils::{
    OWNER, DEFAULT_MIN_LOCKTIME, pow_256, LOCK_MANAGER_ADDRESS, MEMEFACTORY_ADDRESS
};
use unruggable::tokens::interface::{IUnruggableMemecoinDispatcherTrait};
use unruggable::tokens::memecoin::LiquidityPosition;
use unruggable::utils::math::PercentageMath;

#[test]
#[fork("Mainnet")]
fn test_jediswap_integration() {
    let owner = snforge_std::test_address();
    let (memecoin, memecoin_address) = deploy_memecoin_through_factory_with_owner(owner);
    let eth = ERC20ABIDispatcher { contract_address: ETH_ADDRESS() };
    let router = IJediswapRouterDispatcher { contract_address: JEDI_ROUTER_ADDRESS() };
    let factory = IFactoryDispatcher { contract_address: MEMEFACTORY_ADDRESS() };

    let unlock_time = starknet::get_block_timestamp() + DEFAULT_MIN_LOCKTIME;

    // approve spending of eth by factory
    let amount: u256 = 1 * pow_256(10, 18); // 1 ETHER
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.approve(factory.contract_address, amount);
    stop_prank(CheatTarget::One(eth.contract_address));

    let pair_address = factory
        .launch_on_jediswap(
            memecoin_address, ETH_ADDRESS(), amount, LOCK_MANAGER_ADDRESS(), unlock_time
        );

    let pair = IJediswapPairDispatcher { contract_address: pair_address };

    // Test that swaps work correctly

    // Approve required token amounts
    start_prank(CheatTarget::One(eth.contract_address), owner);
    eth.approve(JEDI_ROUTER_ADDRESS(), 1 * pow_256(10, 18));
    stop_prank(CheatTarget::One(eth.contract_address));

    // Max buy cap is 2% of total supply
    // Initial rate is roughly 1 ETH for 21M meme,
    // so max buy is ~ 2% of 1 ETH = 0.02 ETH
    let amount_in = 2 * pow_256(10, 16);
    start_prank(CheatTarget::One(router.contract_address), owner);
    let first_swap = router
        .swap_exact_tokens_for_tokens(
            amountIn: amount_in,
            amountOutMin: 0,
            path: array![ETH_ADDRESS(), memecoin_address],
            to: owner,
            deadline: starknet::get_block_timestamp()
        );
    let first_out = *first_swap[0];

    start_prank(CheatTarget::One(memecoin_address), owner);
    memecoin.approve(JEDI_ROUTER_ADDRESS(), first_out);
    stop_prank(CheatTarget::One(eth.contract_address));

    let _second_swap = router
        .swap_exact_tokens_for_tokens(
            amountIn: first_out,
            amountOutMin: 0,
            path: array![memecoin_address, ETH_ADDRESS()],
            to: owner,
            deadline: starknet::get_block_timestamp()
        );

    // Check token lock
    let locker = ILockManagerDispatcher { contract_address: LOCK_MANAGER_ADDRESS() };
    let lock_address = locker.user_lock_at(owner, 0);
    let token_lock = locker.get_lock_details(lock_address);
    let expected_lock = LockPosition {
        token: pair_address,
        amount: pair.totalSupply(),
        unlock_time: starknet::get_block_timestamp() + DEFAULT_MIN_LOCKTIME,
        owner: owner,
    };

    assert(token_lock.token == expected_lock.token, 'token not locked');
    // can't test for the amount locked as the initial liq provided and the total supply
    // of the pair do not match
    assert(token_lock.unlock_time == expected_lock.unlock_time, 'wrong unlock time');
    assert(token_lock.owner == expected_lock.owner, 'wrong owner');
}

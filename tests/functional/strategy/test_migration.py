import brownie


def test_good_migration(token, strategy, vault, gov, strategist, TestStrategy, chain):
    new_strategy = strategist.deploy(TestStrategy, vault, gov)
    strategy_debt = vault.strategies(strategy)[4]  # totalDebt
    prior_position = token.balanceOf(strategy)
    assert strategy_debt > 0
    assert vault.strategies(new_strategy)[4] == 0
    assert token.balanceOf(new_strategy) == 0

    # Strategist can migrate
    strategy.migrate(new_strategy, {"from": strategist})
    assert vault.strategies(strategy)[4] == 0
    assert vault.strategies(new_strategy)[4] == strategy_debt
    assert token.balanceOf(new_strategy) == prior_position

    chain.undo()

    # Governance can do it too
    strategy.migrate(new_strategy, {"from": gov})
    assert vault.strategies(strategy)[4] == 0
    assert vault.strategies(new_strategy)[4] == strategy_debt
    assert token.balanceOf(new_strategy) == prior_position


def test_bad_migration(token, strategy, gov, strategist, TestStrategy, Vault):
    different_vault = gov.deploy(Vault, token, gov, gov)
    new_strategy = strategist.deploy(TestStrategy, different_vault, gov)

    with brownie.reverts():
        strategy.migrate(new_strategy, {"from": gov})

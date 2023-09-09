from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from utils import harvest_strategy
import pytest


def test_exercise_helper(
    ofvm,
    exercise_helper,
    wftm,
):
    ofvm_whale = accounts.at("0x9aCf8D0315094d33Aa6875B673EB126483C3A2c0", force=True)
    ofvm_before = ofvm.balanceOf(ofvm_whale)
    wftm_before = wftm.balanceOf(ofvm_whale)

    ofvm.approve(exercise_helper, 2**256 - 1, {"from": ofvm_whale})
    fee_before = wftm.balanceOf(exercise_helper.feeAddress())
    exercise_helper.exercise(ofvm_before, {"from": ofvm_whale})
    assert ofvm.balanceOf(ofvm_whale) == 0
    assert wftm_before < wftm.balanceOf(ofvm_whale)
    profit = wftm.balanceOf(ofvm_whale) - wftm_before
    fees = wftm.balanceOf(exercise_helper.feeAddress()) - fee_before
    print(
        "\n🥟 Dumped",
        "{:,.2f}".format(ofvm_before / 1e18),
        "oFVM for",
        "{:,.2f}".format(profit / 1e18),
        "WFTM 👻\n",
    )
    print("\n🤑 Took", "{:,.2f}".format(fees / 1e18), "WFTM in fees\n")

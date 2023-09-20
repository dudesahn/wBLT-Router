from brownie import config, Contract, ZERO_ADDRESS, chain, interface, accounts
from utils import harvest_strategy
import pytest


def test_exercise_helper(
    ofvm,
    exercise_helper,
    wftm,
    fvm,
):
    ofvm_whale = accounts.at("0x9aCf8D0315094d33Aa6875B673EB126483C3A2c0", force=True)
    ofvm_before = ofvm.balanceOf(ofvm_whale)
    wftm_before = wftm.balanceOf(ofvm_whale)

    # control how much we exercise. larger size, more slippage
    to_exercise = ofvm_before / 5
    profit_slippage = 800  # in BPS
    swap_slippage = 100

    ofvm.approve(exercise_helper, 2**256 - 1, {"from": ofvm_whale})
    fee_before = wftm.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a")

    # use our preset slippage and amount
    result = exercise_helper.quoteExerciseProfit(ofvm, to_exercise, 0)
    print("Result", result.dict())
    real_slippage = (result["expectedProfit"] - result["realProfit"]) / result[
        "expectedProfit"
    ]
    print("Slippage:", "{:,.2f}%".format(real_slippage * 100))

    exercise_helper.exercise(
        ofvm, to_exercise, profit_slippage, swap_slippage, {"from": ofvm_whale}
    )

    assert ofvm.balanceOf(ofvm_whale) == ofvm_before - to_exercise
    assert wftm_before < wftm.balanceOf(ofvm_whale)
    profit = wftm.balanceOf(ofvm_whale) - wftm_before
    fees = wftm.balanceOf("0x58761D6C6bF6c4bab96CaE125a2e5c8B1859b48a") - fee_before

    assert fvm.balanceOf(exercise_helper) == 0
    assert wftm.balanceOf(exercise_helper) == 0
    assert ofvm.balanceOf(exercise_helper) == 0

    print(
        "\n🥟 Dumped",
        "{:,.2f}".format(ofvm_before / 1e18),
        "oFVM for",
        "{:,.2f}".format(profit / 1e18),
        "WFTM 👻\n",
    )
    print("\n🤑 Took", "{:,.2f}".format(fees / 1e18), "WFTM in fees\n")

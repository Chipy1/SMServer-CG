from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.filter_recipes import apply_filters, load_game_json

ROOT = Path(__file__).resolve().parents[1]
GENERATED = ROOT / "CraftingRecipes" / "dependencies" / "craftbot_modpack.json"
OVERRIDES = ROOT / "CraftingRecipes" / "dependencies" / "modpack_rebalance.json"
BLACKLIST = ROOT / "Scripts" / "smserver" / "production_blacklist.json"

PISTON_L3 = "46396518-8c29-4da9-81bb-a020f4baf5b2"
MOD_PISTON = "a6d186ad-c9ba-4b6d-922c-6c13dfcea230"
GAME_GRID_BLOCK = "b51ad015-66e9-41b9-916c-277f9c93232d"


class FilterRecipesTests(unittest.TestCase):
    def test_blacklist_removes_output_and_ingredient(self) -> None:
        recipes = [
            {"itemId": "a", "quantity": 1, "ingredientList": [{"itemId": "x", "quantity": 1}]},
            {"itemId": "b", "quantity": 1, "ingredientList": [{"itemId": "blocked", "quantity": 1}]},
            {"itemId": "blocked", "quantity": 1, "ingredientList": [{"itemId": "x", "quantity": 1}]},
        ]

        kept, removed, replaced = apply_filters(recipes, {"blocked"})

        self.assertEqual([recipe["itemId"] for recipe in kept], ["a"])
        self.assertEqual(removed, 2)
        self.assertEqual(replaced, 0)

    def test_override_replaces_recipe_in_place(self) -> None:
        recipes = [
            {"itemId": "a", "quantity": 1, "craftTime": 5, "ingredientList": [{"itemId": "x", "quantity": 1}]},
            {"itemId": "b", "quantity": 1, "craftTime": 5, "ingredientList": [{"itemId": "x", "quantity": 1}]},
        ]
        override = {
            "itemId": "b",
            "quantity": 1,
            "craftTime": 90,
            "ingredientList": [{"itemId": "y", "quantity": 2}],
        }

        kept, removed, replaced = apply_filters(recipes, set(), [override])

        self.assertEqual([recipe["itemId"] for recipe in kept], ["a", "b"])
        self.assertIs(kept[1], override)
        self.assertEqual(removed, 0)
        self.assertEqual(replaced, 1)

    def test_override_for_missing_recipe_is_rejected(self) -> None:
        recipes = [
            {"itemId": "a", "quantity": 1, "ingredientList": [{"itemId": "x", "quantity": 1}]},
        ]
        override = {
            "itemId": "missing",
            "quantity": 1,
            "ingredientList": [{"itemId": "y", "quantity": 1}],
        }

        with self.assertRaises(ValueError):
            apply_filters(recipes, set(), [override])

    def test_override_cannot_use_blacklisted_ingredient(self) -> None:
        recipes = [
            {"itemId": "a", "quantity": 1, "ingredientList": [{"itemId": "x", "quantity": 1}]},
        ]
        override = {
            "itemId": "a",
            "quantity": 1,
            "ingredientList": [{"itemId": "blocked", "quantity": 1}],
        }

        with self.assertRaises(ValueError):
            apply_filters(recipes, {"blocked"}, [override])

    def test_duplicate_override_output_is_rejected(self) -> None:
        recipes = [
            {"itemId": "a", "quantity": 1, "ingredientList": [{"itemId": "x", "quantity": 1}]},
        ]
        override = {
            "itemId": "a",
            "quantity": 1,
            "ingredientList": [{"itemId": "y", "quantity": 1}],
        }

        with self.assertRaises(ValueError):
            apply_filters(recipes, set(), [override, override])


class ModpackRebalanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.generated = {recipe["itemId"]: recipe for recipe in load_game_json(GENERATED)}
        self.overrides = load_game_json(OVERRIDES)

    def test_generated_file_contains_every_override(self) -> None:
        for override in self.overrides:
            with self.subTest(item=override["itemId"]):
                self.assertEqual(self.generated.get(override["itemId"]), override)

    def test_recipes_fit_the_stock_four_slot_craftbot(self) -> None:
        for recipe in self.overrides:
            with self.subTest(item=recipe["itemId"]):
                self.assertLessEqual(len(recipe["ingredientList"]), 4)

    def test_mod_piston_matches_stock_piston_travel(self) -> None:
        stock_piston_range = 11
        mod_piston_range = 255
        required = next(
            ingredient
            for ingredient in self.generated[MOD_PISTON]["ingredientList"]
            if ingredient["itemId"] == PISTON_L3
        )

        self.assertGreaterEqual(required["quantity"] * stock_piston_range, mod_piston_range)

    def test_overrides_still_produce_a_single_part(self) -> None:
        for recipe in self.overrides:
            with self.subTest(item=recipe["itemId"]):
                self.assertEqual(recipe["quantity"], 1)

    def test_indestructible_game_grid_block_is_blocked(self) -> None:
        blacklist = load_game_json(BLACKLIST)["items"]

        self.assertIn(GAME_GRID_BLOCK, blacklist)
        self.assertNotIn(GAME_GRID_BLOCK, self.generated)


if __name__ == "__main__":
    unittest.main()

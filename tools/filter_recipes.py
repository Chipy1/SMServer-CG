#!/usr/bin/env python3
"""Copy a Scrap Mechanic recipe JSON, dropping blacklisted items and applying
local rebalance overrides.

The craftbot grid is loaded by the engine directly from the recipe file, so
filtering g_craftingRecipeSets in Lua removes craftability but not the visible
grid entry. Feed the craftbot a sanitized file instead.

The optional OVERRIDES.json is a list of complete recipe objects. An override
replaces the source recipe with the same output ``itemId``. The generator fails
when an override no longer matches a source recipe so a dependency update is
reviewed instead of silently dropping the rebalance.

Usage:
    python3 tools/filter_recipes.py SOURCE OUTPUT BLACKLIST.json [OVERRIDES.json]
"""

import json
import re
import sys
from collections import Counter


def load_game_json(path):
    with open(path, encoding="utf-8-sig") as handle:
        text = handle.read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r",\s*([}\]])", r"\1", text)
    return json.loads(text)


def index_overrides(overrides):
    by_id = {}
    for recipe in overrides:
        item_id = recipe.get("itemId", "").lower()
        if not item_id:
            raise ValueError("override recipe without itemId")
        if item_id in by_id:
            raise ValueError(f"duplicate override for {item_id}")
        by_id[item_id] = recipe
    return by_id


def validate_recipe(recipe, label):
    if not recipe.get("itemId"):
        raise ValueError(f"{label}: missing itemId")
    if not isinstance(recipe.get("quantity"), int) or recipe["quantity"] < 1:
        raise ValueError(f"{label}: invalid quantity")
    ingredients = recipe.get("ingredientList")
    if not isinstance(ingredients, list) or not ingredients:
        raise ValueError(f"{label}: empty ingredientList")
    for ingredient in ingredients:
        if not ingredient.get("itemId"):
            raise ValueError(f"{label}: ingredient without itemId")
        quantity = ingredient.get("quantity")
        if not isinstance(quantity, int) or quantity < 1:
            raise ValueError(f"{label}: invalid ingredient quantity")


def apply_filters(recipes, blacklist, overrides=()):
    """Filter blacklisted recipes and replace outputs listed in overrides."""
    override_by_id = index_overrides(overrides)
    applied = set()
    kept = []
    removed = 0
    replaced = 0

    for recipe in recipes:
        item_id = recipe.get("itemId", "").lower()
        ingredient_ids = [i.get("itemId", "").lower() for i in recipe.get("ingredientList", [])]

        override = override_by_id.get(item_id)
        if override is not None:
            applied.add(item_id)
            if item_id in blacklist:
                removed += 1
                continue
            blocked = [u for u in (i.get("itemId", "").lower() for i in override.get("ingredientList", [])) if u in blacklist]
            if blocked:
                raise ValueError(f"override {item_id} uses blacklisted ingredients: {', '.join(blocked)}")
            validate_recipe(override, f"override {item_id}")
            kept.append(override)
            replaced += 1
            continue

        if item_id in blacklist or any(u in blacklist for u in ingredient_ids):
            removed += 1
            continue
        kept.append(recipe)

    missing = sorted(set(override_by_id) - applied)
    if missing:
        raise ValueError(
            "overrides no longer match a source recipe: " + ", ".join(missing)
        )

    outputs = Counter(recipe["itemId"].lower() for recipe in kept)
    duplicates = sorted(item_id for item_id, count in outputs.items() if count > 1)
    if duplicates:
        raise ValueError("duplicate recipe outputs: " + ", ".join(duplicates))

    return kept, removed, replaced


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)

    source, output, blacklist_path = sys.argv[1:4]
    overrides_path = sys.argv[4] if len(sys.argv) == 5 else None
    blacklist = set(load_game_json(blacklist_path)["items"].keys())
    overrides = load_game_json(overrides_path) if overrides_path else []

    recipes = load_game_json(source)
    kept, removed, replaced = apply_filters(recipes, blacklist, overrides)

    with open(output, "w", encoding="utf-8") as f:
        json.dump(kept, f, indent="\t")
        f.write("\n")

    print(
        f"{source} -> {output}: kept {len(kept)}, removed {removed}, "
        f"replaced {replaced}"
    )


if __name__ == "__main__":
    main()

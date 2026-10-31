# Id tables (sim → client, once per session) — block B6

Sent after data loading (and again if mods change). Index 0 of every table is "none".

```cpp
struct IdTables {
    std::vector<TerInfo>   ter;    std::vector<FurnInfo>  furn;  std::vector<IdInfo> trap, field, weather;
    std::vector<ItemInfo>  itype;  std::vector<MonInfo>   mtype; std::vector<IdInfo> vpart, body_part;
};
struct IdInfo   { string id, name, looks_like; string symbol; uint8 color; };
struct TerInfo  : IdInfo { uint32 flags_mask; std::vector<string> flags; std::vector<string> connect_groups, connects_to;
                           int move_cost; string roof; bool transparent; };
struct FurnInfo : IdInfo { std::vector<string> flags; int move_cost_mod; bool transparent; };
struct ItemInfo : IdInfo { string category; std::vector<string> materials; int volume_ml, weight_g, length_mm; };
struct MonInfo  : IdInfo { string species, size; int speed; };
```

Until libcdda exists, `tools/coverage/` reads the same facts straight from `cdda/data/json`.

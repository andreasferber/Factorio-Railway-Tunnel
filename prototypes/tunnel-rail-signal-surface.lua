local CollisionMaskUtil = require("__core__/lualib/collision-mask-util")
local tunnelSignalSurfaceCollisionLayer = CollisionMaskUtil.get_first_unused_layer()

data:extend(
    {
        {
            type = "rail-signal",
            name = "railway_tunnel-tunnel_rail_signal_surface",
            animation = {
                direction_count = 1,
                filename = "__core__/graphics/empty.png",
                size = 1
            },
            collision_mask = {tunnelSignalSurfaceCollisionLayer},
            collision_box = {{-0.2, -0.2}, {0.2, 0.2}}
            --selection_box = {{-0.5, -0.5}, {0.5, 0.5}}, -- For testing when we need to select them
        }
    }
)

-- Add our hidden rail signal collision mask to all other rail signals
for _, prototypeTypeName in pairs({"rail-signal", "rail-chain-signal"}) do
    for _, prototype in pairs(data.raw[prototypeTypeName]) do
        local newMask = CollisionMaskUtil.get_mask(prototype)
        CollisionMaskUtil.add_layer(newMask, tunnelSignalSurfaceCollisionLayer)
        prototype.collision_mask = newMask
    end
end
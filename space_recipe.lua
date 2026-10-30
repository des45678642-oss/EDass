-- =====================================================================
--    格雷自動化工廠 - 核心配方數據庫 (recipe.lua)
--    終極結構：納入最低/最高無人機代數、距離、權重與 limit 保險
-- =====================================================================
local recipes = {

  ["label1"] = {
    min_miner_tier = 1,    
    min_drone_tier = 3, 
    max_drone_tier = 5, 
    distance       = 91,    
    weight         = 5,       
    target_amount  = 10000,
    limit          = 1
  },
  
  ["label2"] = {
    min_miner_tier = 1,
    min_drone_tier = 7,
    max_drone_tier = 12,
    distance       = 91,
    weight         = 1,
    target_amount  = 1000,
    limit          = 0
  },

  ["label3"] = {
    min_miner_tier = 1,
    min_drone_tier = 3,
    max_drone_tier = 5,
    distance       = 91,
    weight         = 1,
    target_amount  = 5000,
    limit          = 0
  }
}

return recipes

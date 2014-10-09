-- A count of the different chart types and the actions on them this cycle
SELECT 
  chart_code,user_action, COUNT(user_action) 
FROM 
  dtpp 
-- WHERE 
--   chart_code = 'IAP'
--   OR
--   chart_code = 'APD'
GROUP BY 
  chart_code,user_action;

-------------------------------------

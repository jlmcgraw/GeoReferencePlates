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
-- A count of the different chart types and their statuses 
      SELECT 
	d.chart_code,d.military_use,dg.status, COUNT(dg.status) 
      FROM 
	dtpp as D 
      JOIN 
	dtppGeo as DG 
      ON 
	D.PDF_NAME=DG.PDF_NAME
      WHERE
        (
        D.CHART_CODE = 'APD'            
	  OR
	D.CHART_CODE = 'IAP'
	)
      GROUP BY 
	d.chart_code,d.military_use,dg.status;
      ;
  
-------------------------------------
-- IAPs/APDs that are rotated
      SELECT 
        D.STATE_ID
        ,D.FAA_CODE
        ,D.PDF_NAME
        ,DG.airportLatitude
        ,DG.status
        ,DG.upperLeftLon
        ,DG.upperLeftLat
        ,DG.xMedian
        ,dg.xpixelskew 
        ,DG.yMedian
        ,dg.ypixelskew

      FROM 
	dtpp as D 
      JOIN 
	dtppGeo as DG 
      ON 
	D.PDF_NAME=DG.PDF_NAME
      WHERE  
        D.CHART_CODE = 'APD'            
	  and
        (cast (xpixelskew as real) != 0
        OR
        cast (ypixelskew as real) != 0
        )
      GROUP BY 
	d.chart_code,d.user_action;
      ;
      
-- IAPs/APDs that are rotated
      SELECT 
        D.STATE_ID
        ,D.FAA_CODE
        ,D.PDF_NAME
      FROM 
	dtpp as D 
      JOIN 
	dtppGeo as DG 
      ON 
	D.PDF_NAME=DG.PDF_NAME
      WHERE
      d.military_use = 'N'
--       and
--       d.PDF_NAME not like '%vis%'
           and
      d.PDF_NAME not like '%h%'
      and
        D.CHART_CODE = 'IAP'            
	  and
         dg.status like '%bad%'

      ;
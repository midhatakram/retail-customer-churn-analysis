---DATABASE SETTINGS & BACKUP INITIALIZATION 
create database Online_Retail_Company;
USE Online_Retail_Company;
IF OBJECT_ID('OnlineRetail_Raw','U') IS NOT NULL
    DROP TABLE OnlineRetail_Raw;

SELECT *
INTO OnlineRetail_Raw
FROM online_retail_table;
---DATA CLEANING, STANDARDISATION & DEDUPLICATION 

IF OBJECT_ID('OnlineRetail_Clean','U') IS NOT NULL
    DROP TABLE OnlineRetail_Clean;

SELECT
    IDENTITY(INT,1,1) AS ID,
    InvoiceNo,
    StockCode,
    Description,
    Quantity,
    InvoiceDate,
    UnitPrice,
    CustomerID,
    Country
INTO OnlineRetail_Clean
FROM OnlineRetail_Raw;

ALTER TABLE OnlineRetail_Clean
ADD CONSTRAINT PK_OnlineRetail_Clean
PRIMARY KEY (ID);

UPDATE OnlineRetail_Clean
SET Description = 'UNKNOWN PRODUCT'
WHERE Description IS NULL;

UPDATE OnlineRetail_Clean
SET
    Description = UPPER(TRIM(Description)),
    Country     = UPPER(TRIM(Country)),
    StockCode   = UPPER(TRIM(StockCode)),
    InvoiceNo   = UPPER(TRIM(InvoiceNo));

UPDATE OnlineRetail_Clean
SET Country = 'UNITED KINGDOM'
WHERE Country IN ('UK','U.K.');

--DUPLICATE VALIDATION

SELECT COUNT(*) AS Rows_Before_Dedup
FROM OnlineRetail_Clean;
--REMOVING DUPLICATES
WITH DuplicateRows AS
(
    SELECT
        ID,
        ROW_NUMBER() OVER
        (
            PARTITION BY
                InvoiceNo,
                StockCode,
                Description,
                Quantity,
                InvoiceDate,
                UnitPrice,
                CustomerID,
                Country
            ORDER BY ID
        ) AS RN
    FROM OnlineRetail_Clean
)

DELETE FROM OnlineRetail_Clean
WHERE ID IN
(
    SELECT ID
    FROM DuplicateRows
    WHERE RN > 1
);
--DUPLICATE VALIDATION

SELECT COUNT(*) AS Rows_After_Dedup
FROM OnlineRetail_Clean;
--DESCRIPTION LENGTH CHECK
SELECT MAX(LEN(Description)) AS Max_Description_Length
FROM OnlineRetail_Clean;
---ADDING AND POPULATING ANALYTICS COLUMNS 
ALTER TABLE OnlineRetail_Clean
ADD
    Revenue DECIMAL(18,2),
    OrderYear INT,
    OrderMonth INT;

UPDATE OnlineRetail_Clean
SET
    Revenue= CAST(Quantity * UnitPrice AS DECIMAL(18,2)),
    OrderYear= YEAR(InvoiceDate),
    OrderMonth= MONTH(InvoiceDate);

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN InvoiceNo NVARCHAR(20) NOT NULL;

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN StockCode NVARCHAR(20) NOT NULL;

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN Description NVARCHAR(255) NOT NULL;

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN Quantity INT NOT NULL;

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN InvoiceDate DATETIME NOT NULL;

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN UnitPrice DECIMAL(18,2) NOT NULL;

ALTER TABLE OnlineRetail_Clean
ALTER COLUMN Country NVARCHAR(100) NOT NULL;

SELECT COUNT(*) AS Total_Rows
FROM OnlineRetail_Clean;

SELECT COUNT(*) AS Null_CustomerIDs
FROM OnlineRetail_Clean
WHERE CustomerID IS NULL;

SELECT COUNT(*) AS Negative_Quantity
FROM OnlineRetail_Clean
WHERE Quantity < 0;

SELECT COUNT(*) AS Zero_UnitPrice
FROM OnlineRetail_Clean
WHERE UnitPrice = 0;

SELECT COUNT(*) AS Negative_UnitPrice
FROM OnlineRetail_Clean
WHERE UnitPrice < 0;

SELECT COUNT(DISTINCT CustomerID) AS Unique_Customers
FROM OnlineRetail_Clean;

SELECT COUNT(DISTINCT StockCode) AS Unique_Products
FROM OnlineRetail_Clean;

---OPERATIONAL VIEWS
CREATE OR ALTER VIEW vw_NonProductCodes AS
SELECT DISTINCT
    StockCode,
    Description
FROM OnlineRetail_Clean
WHERE
       StockCode IN
       (
            'POST',
            'D',
            'M',
            'DOT',
            'C2',
            'BANK CHARGES',
            'AMAZONFEE',
            'ADJUST',
            'CRUK'
       )
    OR Description LIKE '%MANUAL%'
    OR Description LIKE '%ADJUST%';

CREATE OR ALTER VIEW vw_Sales AS
SELECT *
FROM OnlineRetail_Clean
WHERE
    Quantity > 0
    AND UnitPrice > 0
    AND CustomerID IS NOT NULL
    AND InvoiceNo NOT LIKE 'C%';

CREATE OR ALTER VIEW vw_Returns AS
SELECT *
FROM OnlineRetail_Clean
WHERE
      Quantity < 0
   OR InvoiceNo LIKE 'C%';

CREATE OR ALTER VIEW vw_FreeItems AS
SELECT *
FROM OnlineRetail_Clean
WHERE
    UnitPrice = 0
    AND Quantity > 0
    AND CustomerID IS NOT NULL;

CREATE OR ALTER VIEW vw_StockAdjustments AS
SELECT *
FROM OnlineRetail_Clean
WHERE
    UnitPrice = 0
    AND Quantity < 0;

CREATE OR ALTER VIEW vw_PriceAnomalies AS
SELECT *
FROM OnlineRetail_Clean
WHERE UnitPrice < 0;

SELECT COUNT(*) AS SalesRows
FROM vw_Sales;

SELECT COUNT(*) AS ReturnRows
FROM vw_Returns;

SELECT COUNT(*) AS FreeItemRows
FROM vw_FreeItems;

SELECT COUNT(*) AS StockAdjustmentRows
FROM vw_StockAdjustments;

SELECT COUNT(*) AS NegativePriceRows
FROM vw_PriceAnomalies;

SELECT COUNT(DISTINCT CustomerID) AS SalesCustomers
FROM vw_Sales;

SELECT COUNT(DISTINCT StockCode) AS SalesProducts
FROM vw_Sales;

SELECT DISTINCT StockCode
FROM vw_NonProductCodes
ORDER BY StockCode;

DROP VIEW IF EXISTS vw_NonProductCodes;
CREATE OR ALTER VIEW vw_NonProductCodes AS
SELECT DISTINCT
    StockCode,
    Description
FROM OnlineRetail_Clean
WHERE StockCode IN
(
    'POST',
    'D',
    'M',
    'DOT',
    'C2',
    'BANK CHARGES',
    'AMAZONFEE',
    'CRUK',
    'B'
);
---ADVANCED CUSTOMER CHURN & HEALTH DIAGNOSTICS
CREATE OR ALTER VIEW vw_DynamicChurnThreshold AS

WITH CustomerVisitDays AS
(
    SELECT DISTINCT
        CustomerID,
        CAST(InvoiceDate AS DATE) AS VisitDate
    FROM vw_Sales
),

OrderGaps AS
(
    SELECT
        CustomerID,
        VisitDate,
        LAG(VisitDate)
            OVER
            (
                PARTITION BY CustomerID
                ORDER BY VisitDate
            ) AS PreviousVisit
    FROM CustomerVisitDays
),

GapCalculation AS
(
    SELECT
        DATEDIFF
        (
            DAY,
            PreviousVisit,
            VisitDate
        ) AS GapDays
    FROM OrderGaps
    WHERE PreviousVisit IS NOT NULL
)

SELECT
    CEILING
    (
        AVG(CAST(GapDays AS FLOAT))
        +
        (2 * STDEV(CAST(GapDays AS FLOAT)))
    ) AS ChurnThreshold
FROM GapCalculation;

SELECT *
FROM vw_DynamicChurnThreshold;

CREATE OR ALTER VIEW vw_CustomerStatus AS

WITH ThresholdValue AS
(
    SELECT ChurnThreshold
    FROM vw_DynamicChurnThreshold
),

CustomerLastPurchase AS
(
    SELECT
        CustomerID,
        MAX(InvoiceDate) AS LastPurchaseDate
    FROM vw_Sales
    GROUP BY CustomerID
)

SELECT
    c.CustomerID,
    c.LastPurchaseDate,
    DATEDIFF(DAY, c.LastPurchaseDate, (SELECT MAX(InvoiceDate) FROM vw_Sales)) AS DaysSinceLastPurchase,
    t.ChurnThreshold,
    CASE
        WHEN DATEDIFF(DAY, c.LastPurchaseDate, (SELECT MAX(InvoiceDate) FROM vw_Sales)) > t.ChurnThreshold
            THEN 'CHURNED'
        WHEN DATEDIFF(DAY, c.LastPurchaseDate, (SELECT MAX(InvoiceDate) FROM vw_Sales)) > (t.ChurnThreshold / 2)
            THEN 'AT RISK'
        ELSE 'ACTIVE'
    END AS CustomerStatus
FROM CustomerLastPurchase c
CROSS JOIN ThresholdValue t;

SELECT TOP 20 *
FROM vw_CustomerStatus
ORDER BY DaysSinceLastPurchase DESC;

CREATE OR ALTER VIEW vw_ChurnRate AS

SELECT
    COUNT(*) AS TotalCustomers,
    SUM(CASE WHEN CustomerStatus = 'CHURNED' THEN 1 ELSE 0 END) AS ChurnedCustomers,
    CAST(
        SUM(CASE WHEN CustomerStatus = 'CHURNED' THEN 1 ELSE 0 END) * 100.0
        / COUNT(*)
        AS DECIMAL(10,2)
    ) AS ChurnRatePercent
FROM vw_CustomerStatus;

SELECT *
FROM vw_ChurnRate;
---PARETO 80/20 ANALYSIS & CUSTOMER VALUE SEGMENTATION
CREATE OR ALTER VIEW vw_ParetoCustomers AS

WITH CustomerRevenue AS
(
    SELECT
        CustomerID,
        SUM(Revenue) AS TotalRevenue
    FROM vw_Sales
    GROUP BY CustomerID
),

RevenueContribution AS
(
    SELECT
        CustomerID,
        TotalRevenue,
      CAST(
            SUM(TotalRevenue) OVER (ORDER BY TotalRevenue DESC) * 100.0
            / SUM(TotalRevenue) OVER ()
            AS DECIMAL(10,2)
        ) AS CumulativeRevenuePercent
    FROM CustomerRevenue
)

SELECT *
FROM RevenueContribution
WHERE CumulativeRevenuePercent <= 80;

SELECT *
FROM vw_DynamicChurnThreshold;

SELECT *
FROM vw_ChurnRate;

SELECT CustomerStatus,
       COUNT(*) AS Customers
FROM vw_CustomerStatus
GROUP BY CustomerStatus;

SELECT COUNT(*)
FROM vw_ParetoCustomers;

CREATE OR ALTER VIEW vw_CustomerSegments AS
SELECT
    CustomerID,
    CustomerStatus
FROM vw_CustomerStatus;

CREATE OR ALTER VIEW vw_ProductPriceTrend AS

WITH FirstPrice AS
(
    SELECT
        StockCode,
        UnitPrice,
        ROW_NUMBER() OVER
        (
            PARTITION BY StockCode
            ORDER BY InvoiceDate ASC
        ) AS rn
    FROM vw_Sales
),

LastPrice AS
(
    SELECT
        StockCode,
        UnitPrice,
        ROW_NUMBER() OVER
        (
            PARTITION BY StockCode
            ORDER BY InvoiceDate DESC
        ) AS rn
    FROM vw_Sales
)

SELECT
    f.StockCode,
    f.UnitPrice AS StartingPrice,
    l.UnitPrice AS CurrentPrice
FROM FirstPrice f
JOIN LastPrice l
    ON f.StockCode = l.StockCode
WHERE f.rn = 1 AND l.rn = 1;

---PRODUCT PERFORMANCE, PRICE TRENDS & TOP/WORST PRODUCTS
CREATE OR ALTER VIEW vw_ProductPerformance AS

WITH SalesData AS
(
    SELECT
        StockCode,
        MAX(Description) AS ProductName,
        SUM(Quantity) AS TotalSold,
        SUM(Revenue) AS GrossRevenue
    FROM vw_Sales
    WHERE StockCode NOT IN
    (
        SELECT StockCode
        FROM vw_NonProductCodes
    )
    GROUP BY StockCode
),

ReturnData AS
(
    SELECT
        StockCode,
        SUM(ABS(Quantity)) AS TotalReturns,

        SUM
        (
            ABS(Quantity) * UnitPrice
        ) AS ReturnValue

    FROM vw_Returns

    WHERE StockCode NOT IN
    (
        SELECT StockCode
        FROM vw_NonProductCodes
    )

    GROUP BY StockCode
)

SELECT

    s.StockCode,
    s.ProductName,

    s.TotalSold,

    ISNULL(r.TotalReturns,0) AS TotalReturns,

    s.GrossRevenue,

    ISNULL(r.ReturnValue,0) AS ReturnValue,

    s.GrossRevenue - ISNULL(r.ReturnValue,0)
        AS NetRevenue,

    CASE
        WHEN (s.TotalSold + ISNULL(r.TotalReturns,0)) > 0
        THEN
            CAST
            (
                ISNULL(r.TotalReturns,0) * 100.0
                /
                (s.TotalSold + ISNULL(r.TotalReturns,0))
                AS DECIMAL(10,2)
            )
        ELSE 0
    END AS ReturnRate,

    p.StartingPrice,
    p.CurrentPrice,

    CAST
    (
        p.CurrentPrice - p.StartingPrice
        AS DECIMAL(10,2)
    ) AS PriceChange

FROM SalesData s

LEFT JOIN ReturnData r
    ON s.StockCode = r.StockCode

LEFT JOIN vw_ProductPriceTrend p
    ON s.StockCode = p.StockCode;


CREATE OR ALTER VIEW vw_Top10BestProducts AS

SELECT TOP 10

    StockCode,
    ProductName,

    CAST(NetRevenue AS DECIMAL(18,2))
        AS NetRevenue,

    CAST(ReturnRate AS DECIMAL(10,2))
        AS ReturnRate,

    TotalSold,
    TotalReturns

FROM vw_ProductPerformance

WHERE TotalSold >= 100

ORDER BY

    NetRevenue DESC,
    ReturnRate ASC;

CREATE OR ALTER VIEW vw_Top10WorstProducts AS

SELECT TOP 10

    StockCode,
    ProductName,

    CAST(NetRevenue AS DECIMAL(18,2))
        AS NetRevenue,

    CAST(ReturnRate AS DECIMAL(10,2))
        AS ReturnRate,

    TotalSold,
    TotalReturns

FROM vw_ProductPerformance

WHERE TotalSold >= 100

ORDER BY

    ReturnRate DESC,
    NetRevenue ASC;

SELECT COUNT(*)
FROM vw_ProductPerformance;

SELECT * FROM vw_Top10BestProducts;

SELECT * FROM vw_Top10WorstProducts;

SELECT TOP 20 *
FROM vw_ProductPerformance
ORDER BY GrossRevenue DESC;

SELECT
    COUNT(*)
FROM vw_ProductPerformance
WHERE StartingPrice IS NULL
   OR CurrentPrice IS NULL;
---PRODUCT RISK ANALYSIS (ROOT CAUSE FOR VIP & CHURNED)
CREATE OR ALTER VIEW vw_AtRiskProductIssues AS

WITH AtRiskCustomers AS
(
    SELECT CustomerID
    FROM vw_CustomerStatus
    WHERE CustomerStatus = 'AT RISK'
)

SELECT
    p.StockCode,
    p.ProductName,
    p.NetRevenue,
    p.TotalSold,
    p.TotalReturns,
    p.ReturnRate,
    p.StartingPrice,
    p.CurrentPrice,
    p.PriceChange,

    CASE
        WHEN p.ReturnRate > 10
             AND p.CurrentPrice > p.StartingPrice * 1.15
        THEN 'QUALITY + PRICE ISSUE'

        WHEN p.ReturnRate > 10
        THEN 'QUALITY ISSUE'

        WHEN p.CurrentPrice > p.StartingPrice * 1.15
        THEN 'PRICE ISSUE'

        ELSE 'STABLE'
    END AS RootCause

FROM vw_ProductPerformance p

WHERE EXISTS
(
    SELECT 1
    FROM vw_Sales s
    INNER JOIN AtRiskCustomers a
        ON s.CustomerID = a.CustomerID
    WHERE s.StockCode = p.StockCode
);

CREATE OR ALTER VIEW vw_ChurnedProductIssues AS

WITH ChurnedCustomers AS
(
    SELECT CustomerID
    FROM vw_CustomerStatus
    WHERE CustomerStatus = 'CHURNED'
)

SELECT
    p.StockCode,
    p.ProductName,
    p.NetRevenue,
    p.TotalSold,
    p.TotalReturns,
    p.ReturnRate,
    p.StartingPrice,
    p.CurrentPrice,
    p.PriceChange,

    CASE
        WHEN p.ReturnRate > 10
             AND p.CurrentPrice > p.StartingPrice * 1.15
        THEN 'QUALITY + PRICE ISSUE'

        WHEN p.ReturnRate > 10
        THEN 'QUALITY ISSUE'

        WHEN p.CurrentPrice > p.StartingPrice * 1.15
        THEN 'PRICE ISSUE'

        ELSE 'STABLE'
    END AS RootCause

FROM vw_ProductPerformance p

WHERE EXISTS
(
    SELECT 1
    FROM vw_Sales s
    INNER JOIN ChurnedCustomers c
        ON s.CustomerID = c.CustomerID
    WHERE s.StockCode = p.StockCode
);

CREATE OR ALTER VIEW vw_VIPCustomers AS

WITH CustomerRevenue AS
(
    SELECT
        CustomerID,
        SUM(Revenue) AS TotalRevenue
    FROM vw_Sales
    GROUP BY CustomerID
),

ThresholdCalc AS
(
    SELECT DISTINCT
        PERCENTILE_CONT(0.9)
        WITHIN GROUP (ORDER BY TotalRevenue)
        OVER() AS VIPThreshold
    FROM CustomerRevenue
)

SELECT
    c.CustomerID,
    c.TotalRevenue
FROM CustomerRevenue c
CROSS JOIN ThresholdCalc t
WHERE c.TotalRevenue >= t.VIPThreshold;

CREATE OR ALTER VIEW vw_VIPProductRiskAnalysis AS

SELECT
    p.StockCode,
    p.ProductName,
    p.NetRevenue,
    p.ReturnRate,
    p.TotalSold,
    p.TotalReturns,
    p.PriceChange,

    CASE
        WHEN p.ReturnRate > 10
             AND p.CurrentPrice > p.StartingPrice * 1.15
        THEN 'DOUBLE TROUBLE'

        WHEN p.ReturnRate > 10
        THEN 'CRITICAL QUALITY ISSUE'

        WHEN p.CurrentPrice > p.StartingPrice * 1.15
        THEN 'VIP PRICE RISK'

        ELSE 'LOW RISK'
    END AS VIPRisk

FROM vw_ProductPerformance p

WHERE EXISTS
(
    SELECT 1
    FROM vw_Sales s
    INNER JOIN vw_VIPCustomers v
        ON s.CustomerID = v.CustomerID
    WHERE s.StockCode = p.StockCode
);

SELECT RootCause,
       COUNT(*) AS Products
FROM vw_AtRiskProductIssues
GROUP BY RootCause;

SELECT RootCause,
       COUNT(*) AS Products
FROM vw_ChurnedProductIssues
GROUP BY RootCause;

SELECT COUNT(*)
FROM vw_VIPCustomers;

SELECT VIPRisk,
       COUNT(*) AS Products
FROM vw_VIPProductRiskAnalysis
GROUP BY VIPRisk;
---BUSINESS TRENDS & GEOGRAPHICAL PERFORMANCE VIEWS
CREATE OR ALTER VIEW vw_MonthlySalesTrend AS

SELECT
    OrderYear,
    OrderMonth,

    SUM(Revenue) AS TotalRevenue,
    SUM(Quantity) AS UnitsSold,
    COUNT(DISTINCT InvoiceNo) AS TotalOrders

FROM vw_Sales

GROUP BY
    OrderYear,
    OrderMonth;

CREATE OR ALTER VIEW vw_MonthlyOrderTrend AS

SELECT
    OrderYear,
    OrderMonth,

    COUNT(DISTINCT InvoiceNo) AS TotalOrders,
    COUNT(DISTINCT CustomerID) AS ActiveCustomers

FROM vw_Sales

GROUP BY
    OrderYear,
    OrderMonth;

CREATE OR ALTER VIEW vw_CountryPerformance AS

SELECT
    Country,

    SUM(Revenue) AS TotalRevenue,
    SUM(Quantity) AS UnitsSold,
    COUNT(DISTINCT CustomerID) AS Customers,
    COUNT(DISTINCT InvoiceNo) AS Orders

FROM vw_Sales

GROUP BY Country;

CREATE OR ALTER VIEW vw_CountryCustomerAnalysis AS

SELECT
    Country,

    COUNT(DISTINCT CustomerID) AS CustomerCount,
    SUM(Revenue) AS RevenueGenerated

FROM vw_Sales

GROUP BY Country;

SELECT *
FROM vw_MonthlySalesTrend
ORDER BY OrderYear, OrderMonth;

SELECT TOP 10 *
FROM vw_CountryPerformance
ORDER BY TotalRevenue DESC;

SELECT TOP 10 *
FROM vw_CountryCustomerAnalysis
ORDER BY CustomerCount DESC;

CREATE OR ALTER VIEW vw_CustomerValueSegments AS

WITH CustomerRevenue AS
(
    SELECT
        CustomerID,
        SUM(Revenue) AS TotalRevenue
    FROM vw_Sales
    GROUP BY CustomerID
)

SELECT
    CustomerID,
    TotalRevenue,

    CASE
        WHEN TotalRevenue >= 10000 THEN 'HIGH VALUE'
        WHEN TotalRevenue >= 2500 THEN 'MEDIUM VALUE'
        ELSE 'LOW VALUE'
    END AS CustomerSegment

FROM CustomerRevenue;

SELECT
    CustomerSegment,
    COUNT(*) AS Customers
FROM vw_CustomerValueSegments
GROUP BY CustomerSegment;
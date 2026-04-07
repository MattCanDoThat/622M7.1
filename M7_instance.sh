#!/bin/bash
set -euo pipefail

# ----------------------------
# On my honor, as an Aggie, I have neither given nor received unauthorized assistance on this assignment.
# I further affirm that I have not and will not provide this code to any person, platform, or repository,
# without the express written permission of Dr. Gomillion.
# I understand that any violation of these standards will have serious repercussions.
# ----------------------------

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

touch /root/1-script-started

# ── Progress logging ───────────────
ProgressLog="/var/log/user-data-progress.log"
touch "$ProgressLog"
chmod 644 "$ProgressLog"

TotalSteps=9
CurrentStep=0

NextStep() {
  CurrentStep=$((CurrentStep+1))
  Percent=$((CurrentStep*100/TotalSteps))
  {
    echo ""
    echo "================================================================="
    echo "STEP $CurrentStep of $TotalSteps"
    echo "$1"
    echo "================================================================="
  } | tee -a "$ProgressLog"
}

LogStatus() {
  echo "Status: $1" | tee -a "$ProgressLog"
}

# ── SSH Watcher: smooth ASCII bar + STEP X/7 + label + spinner ─
# Usage after SSH: watchud
# Auto-exits at STEP 7 with a deployment-complete message.
# -------------------------------------------------------------------

cat > /usr/local/bin/watch-userdata-progress <<'EOF'
#!/bin/bash
set -u

ProgressLog="/var/log/user-data-progress.log"
TotalBarWidth=24
RefreshSeconds=0.5

if [ ! -f "$ProgressLog" ]; then
  echo "Progress log not found: $ProgressLog"
  exit 1
fi

# Colors only when output is a real terminal
if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_CYAN=$'\033[36m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_WHITE=$'\033[97m'
else
  C_RESET=""
  C_DIM=""
  C_BOLD=""
  C_CYAN=""
  C_YELLOW=""
  C_GREEN=""
  C_WHITE=""
fi

Cols=$(tput cols 2>/dev/null || echo 120)

DrawBar() {
  local Percent="$1"
  local Filled=$((Percent * TotalBarWidth / 100))
  local Empty=$((TotalBarWidth - Filled))

  printf "["
  if [ "$Filled" -gt 0 ]; then
    printf "%s" "${C_CYAN}"
    printf "%0.s#" $(seq 1 "$Filled")
    printf "%s" "${C_RESET}"
  fi
  if [ "$Empty" -gt 0 ]; then
    printf "%s" "${C_DIM}"
    printf "%0.s-" $(seq 1 "$Empty")
    printf "%s" "${C_RESET}"
  fi
  printf "] %s%%" "$Percent"
}

GetLatestStepLine() {
  grep -E "STEP [0-9]+ of [0-9]+" "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

GetLatestPercent() {
  local line StepNow StepTotal
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    StepNow=$(echo "$line" | sed -n 's/STEP \([0-9]\+\) of.*/\1/p')
    StepTotal=$(echo "$line" | sed -n 's/STEP [0-9]\+ of \([0-9]\+\).*/\1/p')
    echo $(( StepNow * 100 / StepTotal ))
  else
    echo "0"
  fi
}

GetLatestStepNumbers() {
  local line
  line="$(GetLatestStepLine)"
  if [ -n "$line" ]; then
    echo "$line" | sed -n 's/STEP \([0-9]\+\) of \([0-9]\+\).*/\1 \2/p'
  else
    echo "0 0"
  fi
}

GetLatestLabel() {
  awk '/STEP [0-9]+ of [0-9]+/{getline; print}' "$ProgressLog" 2>/dev/null | tail -n 1 || true
}

RenderLine() {
  local Percent="$1"
  local StepNow="$2"
  local StepTotal="$3"
  local Label="$4"
  local Frame="$5"

  local Bar StepText StepPlain
  Bar="$(DrawBar "$Percent")"

  if [ "${StepTotal:-0}" -gt 0 ]; then
    StepText="${C_GREEN}STEP ${StepNow}/${StepTotal}${C_RESET}"
    StepPlain="STEP ${StepNow}/${StepTotal}"
  else
    StepText=""
    StepPlain=""
  fi

  # Fixed visible width: "Deploying " (9) + bar (~30) + "  " + step + "  " + spinner (1) + padding (4)
  local FixedLen=$(( 9 + 30 + 2 + ${#StepPlain} + 2 + 1 + 4 ))
  local MaxLabel=$(( Cols - FixedLen ))
  [ "$MaxLabel" -lt 8 ] && MaxLabel=8
  local TruncLabel="${Label:0:$MaxLabel}"

  # \r\033[2K clears the entire current line before redrawing — prevents
  # ANSI-inflated line width from wrapping and leaving ghost fragments on right
  printf "\r\033[2K"
  printf "${C_WHITE}Deploying${C_RESET} %s  ${C_YELLOW}%s${C_RESET}" \
    "$Bar" "$Frame"
}

echo ""
echo "${C_BOLD}Watching EC2 user-data progress${C_RESET} (Ctrl+C to stop)"
echo ""

LastLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo 0)

TargetPercent="$(GetLatestPercent)"
ShownPercent="$TargetPercent"
read -r StepNow StepTotal <<<"$(GetLatestStepNumbers)"
CurrentLabel="$(GetLatestLabel)"
[ -z "${CurrentLabel:-}" ] && CurrentLabel="Starting..."

# Print the current step banner on startup
if [ "${StepNow:-0}" -gt 0 ]; then
  echo ""
  printf "${C_DIM}=================================================================${C_RESET}\n"
  printf "${C_GREEN}STEP %s of %s${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$StepNow" "$StepTotal" "$CurrentLabel"
  printf "${C_DIM}=================================================================${C_RESET}\n"
fi

i=0
frames='|/-\'

while true; do
  CurrentLineCount=$(wc -l < "$ProgressLog" 2>/dev/null || echo "$LastLineCount")

  # Only print STEP banner lines from newly appended log content.
  # Suppressing Status: lines and separators prevents them from pushing
  # the dashboard bar to a new line each refresh cycle (multiline stacking).
  if [ "$CurrentLineCount" -gt "$LastLineCount" ]; then
    NewLines=$(sed -n "$((LastLineCount+1)),${CurrentLineCount}p" "$ProgressLog" 2>/dev/null || true)
    if echo "$NewLines" | grep -qE "^STEP [0-9]+ of [0-9]+"; then
      printf "\r%-*s\n" "$Cols" " "
      # Print Deployed line for the step that just finished
      if [ "${StepNow:-0}" -gt 0 ]; then
        FullBar="$(DrawBar 100)"
        printf "${C_WHITE}Deployed  ${C_RESET}%s\n\n" "$FullBar"
      fi
      # Print separator, step line, and label for the new step — colored to match startup
      NewStepNum=$(echo "$NewLines" | grep -oE "STEP [0-9]+" | tail -1 | grep -oE "[0-9]+")
      NewStepLbl=$(echo "$NewLines" | awk '/^STEP [0-9]+ of [0-9]+/{getline; print; exit}')
      NewStepTot=$(echo "$NewLines" | grep -oE "STEP [0-9]+ of [0-9]+" | tail -1 | grep -oE "[0-9]+$")
      echo ""
      printf "${C_DIM}=================================================================${C_RESET}\n"
      printf "${C_GREEN}STEP %s of %s${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$NewStepNum" "$NewStepTot" "$NewStepLbl"
      printf "${C_DIM}=================================================================${C_RESET}\n"
    fi
    LastLineCount="$CurrentLineCount"
  fi

  # Update targets from log
  NewTarget="$(GetLatestPercent)"
  [ -n "${NewTarget:-}" ] && TargetPercent="$NewTarget"

  read -r NewStepNow NewStepTotal <<<"$(GetLatestStepNumbers)"
  [ -n "${NewStepNow:-}" ] && StepNow="$NewStepNow"
  [ -n "${NewStepTotal:-}" ] && StepTotal="$NewStepTotal"

  NewLabel="$(GetLatestLabel)"
  [ -n "${NewLabel:-}" ] && CurrentLabel="$NewLabel"

  # Smooth-fill toward the target
  if [ "$ShownPercent" -lt "$TargetPercent" ]; then
    ShownPercent=$((ShownPercent+1))
  elif [ "$ShownPercent" -gt "$TargetPercent" ]; then
    ShownPercent="$TargetPercent"
  fi

  # Completion check — STEP 9 of 9
  if tail -n 50 "$ProgressLog" 2>/dev/null | grep -q "STEP 9 of 9"; then
    FullBar="$(DrawBar 100)"
    printf "\r%-*s\n" "$Cols" " "
    printf "${C_WHITE}Deployed  ${C_RESET}%s\n\n" "$FullBar"
    printf "${C_GREEN}  Deployment complete — MariaDB + MongoDB pipeline ready${C_RESET}\n"
    printf "  ${C_DIM}Run: mongosh FurnitureDB --eval 'db.Customers.countDocuments({})'${C_RESET}\n\n"
    exit 0
  fi

  frame="${frames:i%4:1}"
  RenderLine "$ShownPercent" "$StepNow" "$StepTotal" "$CurrentLabel" "$frame"

  i=$((i+1))
  sleep "$RefreshSeconds"
done
EOF

chmod 755 /usr/local/bin/watch-userdata-progress

# ── Create watchud shortcut command ─────────────────────────

cat > /usr/local/bin/watchud <<'EOF'
#!/bin/bash
exec /usr/local/bin/watch-userdata-progress
EOF
chmod 755 /usr/local/bin/watchud

if [ -f /home/ubuntu/.bashrc ] && ! grep -q "alias watchud=" /home/ubuntu/.bashrc 2>/dev/null; then
  echo "" >> /home/ubuntu/.bashrc
  echo "alias watchud='/usr/local/bin/watchud'" >> /home/ubuntu/.bashrc
fi
chown ubuntu:ubuntu /home/ubuntu/.bashrc 2>/dev/null || true

# ── STEP 1: System prep ─────────────────────────────────────
NextStep "System preparation and package updates"
LogStatus "Running apt update/upgrade"
apt-get update -y
apt-get upgrade -y
apt-get install -y apt-transport-https curl unzip wget jq
sleep 8
LogStatus "Prerequisites installed"

# ── STEP 2: Install MariaDB 11.8 ────────────────────────────
NextStep "Installing MariaDB 11.8"
sleep 5
LogStatus "Adding MariaDB 11.8 repo"
mkdir -p /etc/apt/keyrings
curl -o /etc/apt/keyrings/mariadb-keyring.pgp \
  'https://mariadb.org/mariadb_release_signing_key.pgp'

cat > /etc/apt/sources.list.d/mariadb.sources << 'REPOEOF'
X-Repolib-Name: MariaDB
Types: deb
URIs: https://mirrors.accretive-networks.net/mariadb/repo/11.8/ubuntu
Suites: noble
Components: main main/debug
Signed-By: /etc/apt/keyrings/mariadb-keyring.pgp
REPOEOF

apt-get update -y
apt-get install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb
systemctl is-active --quiet mariadb || { echo "ERROR: MariaDB did not start"; exit 1; }
sleep 20
LogStatus "MariaDB 11.8 running"

# ── STEP 3: Install MongoDB Community Edition ────────────────
NextStep "Installing MongoDB Community Edition"
sleep 5
LogStatus "Adding MongoDB 8.0 repo"
curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc \
  | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg

echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] \
https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" \
  | tee /etc/apt/sources.list.d/mongodb-org-8.0.list

apt-get update -y
apt-get install -y mongodb-org
systemctl enable mongod
systemctl start mongod
systemctl is-active --quiet mongod || { echo "ERROR: mongod did not start"; exit 1; }
sleep 10
LogStatus "MongoDB 7.0 running"

# ── STEP 4: Create mbennett user + working directory ────────
NextStep "Creating Linux user mbennett and working directory"
sleep 5
if id "mbennett" &>/dev/null; then
  LogStatus "User mbennett already exists"
else
  useradd -m -s /bin/bash "mbennett"
  LogStatus "Created Linux user mbennett"
fi
# Open to 755 so root can read SQL files without sudo workaround
chmod 755 /home/mbennett
LogStatus "mbennett home directory ready"

# ── STEP 5: Download and extract dataset ────────────────────
NextStep "Downloading dataset from 622.gomillion.org"
sleep 5
LogStatus "Downloading dataset zip"
sudo -u mbennett wget -O /home/mbennett/313007119.zip \
  "https://622.gomillion.org/data/313007119.zip"

[ ! -s /home/mbennett/313007119.zip ] && \
  { echo "ERROR: Download failed or zip is empty"; exit 1; }

LogStatus "Extracting dataset"
sudo -u mbennett unzip -o /home/mbennett/313007119.zip -d /home/mbennett

for f in customers.csv orders.csv orderlines.csv products.csv; do
  [ ! -f /home/mbennett/$f ] && \
    { echo "ERROR: Missing $f after unzip"; exit 1; }
done
LogStatus "Dataset downloaded and verified (4 CSVs present)"

# ── STEP 6: Generate etl.sql ────────────────────────────────
NextStep "Generating etl.sql"
sleep 8
LogStatus "Writing etl.sql"

cat > /home/mbennett/etl.sql << 'ETLEOF'
DROP DATABASE IF EXISTS POS;
CREATE DATABASE POS;
USE POS;

CREATE TABLE City
(
  zip   DECIMAL(5) ZEROFILL NOT NULL,
  city  VARCHAR(32)         NOT NULL,
  state VARCHAR(4)          NOT NULL,
  PRIMARY KEY (zip)
) ENGINE=InnoDB;

CREATE TABLE Customer
(
  id        SERIAL       NOT NULL,
  firstName VARCHAR(32)  NOT NULL,
  lastName  VARCHAR(30)  NOT NULL,
  email     VARCHAR(128) NULL,
  address1  VARCHAR(100) NULL,
  address2  VARCHAR(50)  NULL,
  phone     VARCHAR(32)  NULL,
  birthdate DATE         NULL,
  zip       DECIMAL(5) ZEROFILL NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_customer_city
    FOREIGN KEY (zip) REFERENCES City(zip)
) ENGINE=InnoDB;

CREATE TABLE Product
(
  id                SERIAL         NOT NULL,
  name              VARCHAR(128)   NOT NULL,
  currentPrice      DECIMAL(6,2)   NOT NULL,
  availableQuantity INT            NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE `Order`
(
  id          SERIAL          NOT NULL,
  datePlaced  DATE            NULL,
  dateShipped DATE            NULL,
  customer_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_order_customer
    FOREIGN KEY (customer_id) REFERENCES Customer(id)
) ENGINE=InnoDB;

CREATE TABLE Orderline
(
  order_id   BIGINT UNSIGNED NOT NULL,
  product_id BIGINT UNSIGNED NOT NULL,
  quantity   INT             NOT NULL,
  PRIMARY KEY (order_id, product_id),
  CONSTRAINT fk_orderline_order
    FOREIGN KEY (order_id) REFERENCES `Order`(id),
  CONSTRAINT fk_orderline_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE PriceHistory
(
  id         SERIAL          NOT NULL,
  oldPrice   DECIMAL(6,2)    NULL,
  newPrice   DECIMAL(6,2)    NOT NULL,
  ts         TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  product_id BIGINT UNSIGNED NOT NULL,
  PRIMARY KEY (id),
  CONSTRAINT fk_pricehistory_product
    FOREIGN KEY (product_id) REFERENCES Product(id)
) ENGINE=InnoDB;

CREATE TABLE staging_customer
(
  ID VARCHAR(50), FN VARCHAR(255), LN VARCHAR(255),
  CT VARCHAR(255), ST VARCHAR(255), ZP VARCHAR(50),
  S1 VARCHAR(255), S2 VARCHAR(255), EM VARCHAR(255), BD VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orders
(
  OID VARCHAR(50), CID VARCHAR(50), Ordered VARCHAR(50), Shipped VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_orderlines
(
  OID VARCHAR(50), PID VARCHAR(50)
) ENGINE=InnoDB;

CREATE TABLE staging_products
(
  ID VARCHAR(50), Name VARCHAR(255), Price VARCHAR(50), Quantity_on_Hand VARCHAR(50)
) ENGINE=InnoDB;

LOAD DATA LOCAL INFILE '/home/mbennett/customers.csv'
INTO TABLE staging_customer
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orders.csv'
INTO TABLE staging_orders
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/orderlines.csv'
INTO TABLE staging_orderlines
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

LOAD DATA LOCAL INFILE '/home/mbennett/products.csv'
INTO TABLE staging_products
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
(@ID, @Name, @Price, @QOH)
SET ID=@ID, Name=@Name, Price=@Price, Quantity_on_Hand=@QOH;

INSERT INTO City (zip, city, state)
SELECT DISTINCT
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED),
  CT, ST
FROM staging_customer
WHERE NULLIF(ZP,'') IS NOT NULL;

INSERT INTO Customer (id, firstName, lastName, email, address1, address2, phone, birthdate, zip)
SELECT
  CAST(ID AS UNSIGNED), FN, LN, NULLIF(EM,''), NULLIF(S1,''), NULLIF(S2,''),
  NULL, STR_TO_DATE(NULLIF(BD,''), '%m/%d/%Y'),
  CAST(LPAD(NULLIF(ZP,''), 5, '0') AS UNSIGNED)
FROM staging_customer;

INSERT INTO Product (id, name, currentPrice, availableQuantity)
SELECT
  CAST(ID AS UNSIGNED), Name,
  CAST(REPLACE(REPLACE(NULLIF(Price,''), '$', ''), ',', '') AS DECIMAL(6,2)),
  CAST(NULLIF(Quantity_on_Hand,'') AS UNSIGNED)
FROM staging_products;

INSERT INTO `Order` (id, datePlaced, dateShipped, customer_id)
SELECT
  CAST(OID AS UNSIGNED),
  CASE WHEN NULLIF(Ordered,'') IS NULL OR LOWER(Ordered)='cancelled' THEN NULL
       ELSE DATE(STR_TO_DATE(Ordered, '%Y-%m-%d %H:%i:%s')) END,
  CASE WHEN NULLIF(Shipped,'') IS NULL OR LOWER(Shipped)='cancelled' THEN NULL
       ELSE DATE(STR_TO_DATE(Shipped, '%Y-%m-%d %H:%i:%s')) END,
  CAST(CID AS UNSIGNED)
FROM staging_orders;

INSERT INTO Orderline (order_id, product_id, quantity)
SELECT CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED), COUNT(*)
FROM staging_orderlines
GROUP BY CAST(OID AS UNSIGNED), CAST(PID AS UNSIGNED);

INSERT INTO PriceHistory (oldPrice, newPrice, product_id)
SELECT NULL, currentPrice, id FROM Product;

DROP TABLE staging_customer;
DROP TABLE staging_orders;
DROP TABLE staging_orderlines;
DROP TABLE staging_products;

ETLEOF

chown mbennett:mbennett /home/mbennett/etl.sql
chmod 644 /home/mbennett/etl.sql
LogStatus "etl.sql written"

# ── STEP 7: Generate json.sql ────────────────────────────────
NextStep "Generating json.sql"
sleep 8
LogStatus "Writing json.sql"

cat > /home/mbennett/json.sql << 'JSONEOF'
USE POS;

-- prod.json
SELECT JSON_OBJECT(
    'ProductID',    p.id,
    'currentPrice', p.currentPrice,
    'productName',  p.name,
    'customers',    JSON_ARRAYAGG(
                        JSON_OBJECT(
                            'CustomerID',    c.id,
                            'customer_name', CONCAT(c.firstName, ' ', c.lastName)
                        )
                    )
)
INTO OUTFILE '/var/lib/mysql-files/prod.json'
LINES TERMINATED BY '\n'
FROM Product p
JOIN (
    SELECT DISTINCT ol.product_id, o.customer_id
    FROM Orderline ol
    JOIN `Order` o ON o.id = ol.order_id
) pc ON pc.product_id = p.id
JOIN Customer c ON c.id = pc.customer_id
GROUP BY p.id, p.currentPrice, p.name;

-- cust.json
WITH ItemsAgg AS (
    SELECT
        ol.order_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',   ol.product_id,
                'Quantity',    ol.quantity,
                'ProductName', p.name
            )
        )                                 AS items_json,
        SUM(p.currentPrice * ol.quantity) AS order_total
    FROM Orderline ol
    JOIN Product   p ON p.id = ol.product_id
    GROUP BY ol.order_id
),

OrdersAgg AS (
    SELECT
        o.customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'OrderTotal', ROUND(ia.order_total, 2),
                'OrderDate',  DATE_FORMAT(o.datePlaced,  '%Y-%m-%d'),
                'ShipDate',   DATE_FORMAT(o.dateShipped, '%Y-%m-%d'),
                'Items',      ia.items_json
            )
        ) AS orders_json
    FROM `Order`  o
    JOIN ItemsAgg ia ON ia.order_id = o.id
    GROUP BY o.customer_id
)

SELECT JSON_OBJECT(
    'customer_name',     CONCAT(c.firstName, ' ', c.lastName),
    'printed_address_1', CASE
                             WHEN c.address2 IS NULL OR c.address2 = ''
                                 THEN c.address1
                             ELSE CONCAT(c.address1, ' ', c.address2)
                         END,
    'printed_address_2', CONCAT(ct.city, ', ', ct.state, '   ', LPAD(c.zip, 5, '0')),
    'orders',            oa.orders_json
)
INTO OUTFILE '/var/lib/mysql-files/cust.json'
LINES TERMINATED BY '\n'
FROM Customer  c
JOIN City      ct ON ct.zip         = c.zip
JOIN OrdersAgg oa ON oa.customer_id = c.id;

-- custom1.json
WITH StateOrderCounts AS (
    SELECT
        ct.state,
        COUNT(DISTINCT o.id) AS total_orders
    FROM Customer  c
    JOIN City      ct ON ct.zip        = c.zip
    JOIN `Order`   o  ON o.customer_id = c.id
    GROUP BY ct.state
),

StateProductRev AS (
    SELECT
        ct.state,
        p.id                                        AS product_id,
        p.name                                      AS product_name,
        SUM(ol.quantity)                            AS units_sold,
        ROUND(SUM(p.currentPrice * ol.quantity), 2) AS product_revenue
    FROM Customer  c
    JOIN City      ct ON ct.zip        = c.zip
    JOIN `Order`   o  ON o.customer_id = c.id
    JOIN Orderline ol ON ol.order_id   = o.id
    JOIN Product   p  ON p.id          = ol.product_id
    GROUP BY ct.state, p.id, p.name
),

TopStateProducts AS (
    SELECT *
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY state
                   ORDER BY product_revenue DESC
               ) AS rn
        FROM StateProductRev
    ) ranked
    WHERE rn <= 10
)

SELECT JSON_OBJECT(
    'state',         tsp.state,
    'total_revenue', ROUND(SUM(tsp.product_revenue), 2),
    'total_orders',  soc.total_orders,
    'top_products',  JSON_ARRAYAGG(
                         JSON_OBJECT(
                             'ProductID',       tsp.product_id,
                             'productName',     tsp.product_name,
                             'units_sold',      tsp.units_sold,
                             'product_revenue', tsp.product_revenue
                         )
                     )
)
INTO OUTFILE '/var/lib/mysql-files/custom1.json'
LINES TERMINATED BY '\n'
FROM TopStateProducts tsp
JOIN StateOrderCounts soc ON soc.state = tsp.state
GROUP BY tsp.state, soc.total_orders;

-- custom2.json
WITH CustomerOrderTotals AS (
    SELECT
        o.customer_id,
        o.id                              AS order_id,
        SUM(p.currentPrice * ol.quantity) AS order_value
    FROM `Order`   o
    JOIN Orderline ol ON ol.order_id = o.id
    JOIN Product   p  ON p.id        = ol.product_id
    GROUP BY o.customer_id, o.id
),

CustomerSummary AS (
    SELECT
        customer_id,
        COUNT(order_id)            AS total_orders,
        ROUND(SUM(order_value), 2) AS lifetime_spend,
        ROUND(AVG(order_value), 2) AS avg_order_value
    FROM CustomerOrderTotals
    GROUP BY customer_id
),

CustomerProductSpend AS (
    SELECT
        o.customer_id,
        p.id                                        AS product_id,
        p.name                                      AS product_name,
        SUM(ol.quantity)                            AS times_purchased,
        ROUND(SUM(p.currentPrice * ol.quantity), 2) AS total_spent
    FROM `Order`   o
    JOIN Orderline ol ON ol.order_id = o.id
    JOIN Product   p  ON p.id        = ol.product_id
    GROUP BY o.customer_id, p.id, p.name
),

TopProductsAgg AS (
    SELECT
        customer_id,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'ProductID',       product_id,
                'productName',     product_name,
                'times_purchased', times_purchased,
                'total_spent',     total_spent
            )
        ) AS top_products_json
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY customer_id
                   ORDER BY total_spent DESC
               ) AS rn
        FROM CustomerProductSpend
    ) ranked
    WHERE rn <= 3
    GROUP BY customer_id
)

SELECT JSON_OBJECT(
    'CustomerID',      c.id,
    'customer_name',   CONCAT(c.firstName, ' ', c.lastName),
    'email',           c.email,
    'lifetime_spend',  cs.lifetime_spend,
    'total_orders',    cs.total_orders,
    'avg_order_value', cs.avg_order_value,
    'top_products',    tpa.top_products_json
)
INTO OUTFILE '/var/lib/mysql-files/custom2.json'
LINES TERMINATED BY '\n'
FROM Customer       c
JOIN CustomerSummary cs  ON cs.customer_id  = c.id
JOIN TopProductsAgg  tpa ON tpa.customer_id = c.id;
JSONEOF

chown mbennett:mbennett /home/mbennett/json.sql
chmod 644 /home/mbennett/json.sql
LogStatus "json.sql written"

# Generate title_case.sql — creates function + updates City table
# Must be run separately with --delimiter so BEGIN...END parses correctly
cat > /home/mbennett/title_case.sql << 'TCEOF'
USE POS//
DROP FUNCTION IF EXISTS title_case//
CREATE FUNCTION title_case(str VARCHAR(255))
RETURNS VARCHAR(255)
DETERMINISTIC
BEGIN
    DECLARE result VARCHAR(255) DEFAULT '';
    DECLARE word VARCHAR(255);
    DECLARE remainder VARCHAR(255) DEFAULT str;
    DECLARE pos INT;
    WHILE LENGTH(remainder) > 0 DO
        SET pos = LOCATE(' ', remainder);
        IF pos = 0 THEN
            SET word = remainder;
            SET remainder = '';
        ELSE
            SET word = SUBSTRING(remainder, 1, pos - 1);
            SET remainder = SUBSTRING(remainder, pos + 1);
        END IF;
        SET result = CONCAT(result, UPPER(LEFT(word, 1)), LOWER(SUBSTRING(word, 2)), ' ');
    END WHILE;
    RETURN TRIM(result);
END//
UPDATE City SET city = title_case(city)//
DROP FUNCTION IF EXISTS title_case//
TCEOF

chown mbennett:mbennett /home/mbennett/title_case.sql
chmod 644 /home/mbennett/title_case.sql
LogStatus "title_case.sql written"

# ── STEP 8: Run ETL then JSON export ────────────────────────
NextStep "Running etl.sql and json.sql"

LogStatus "Running etl.sql — building POS database"
mariadb --local-infile=1 < /home/mbennett/etl.sql
if [ $? -ne 0 ]; then
  echo "ERROR: etl.sql failed. Check /var/log/user-data.log"
  exit 1
fi
LogStatus "etl.sql complete — POS database built"

LogStatus "Applying title case to city names"
mariadb --delimiter="//" < /home/mbennett/title_case.sql
if [ $? -ne 0 ]; then
  echo "ERROR: title_case.sql failed. Check /var/log/user-data.log"
  exit 1
fi
LogStatus "City names updated to proper title case"

# Ensure the secure file output directory exists with correct ownership.
# MariaDB 11.8 from the official repo does not create this automatically.
mkdir -p /var/lib/mysql-files
chown mysql:mysql /var/lib/mysql-files
chmod 755 /var/lib/mysql-files

# Clean up any stale JSON files from a previous run so INTO OUTFILE
# does not fail with "File already exists"
rm -f /var/lib/mysql-files/prod.json \
      /var/lib/mysql-files/cust.json \
      /var/lib/mysql-files/custom1.json \
      /var/lib/mysql-files/custom2.json

LogStatus "Running json.sql — generating NDJSON exports"
mariadb < /home/mbennett/json.sql
if [ $? -ne 0 ]; then
  echo "ERROR: json.sql failed. Check /var/log/user-data.log"
  exit 1
fi
LogStatus "json.sql complete — 4 NDJSON files generated"

# Make JSON files readable by the ubuntu user for easy inspection
chown ubuntu:ubuntu /var/lib/mysql-files/*.json 2>/dev/null || true

echo ""
echo "  JSON exports complete."
ls -lh /var/lib/mysql-files/*.json

# ── STEP 9: Generate sync.sh, initial MongoDB import, cron ──
NextStep "Generating sync.sh, loading MongoDB, and scheduling cron"
sleep 5

LogStatus "Writing sync.sh"
cat > /home/mbennett/sync.sh << 'SYNCEOF'
#!/bin/bash
# ============================================================
#  sync.sh  |  ISTM 622 – Module 7
#  Data Pipeline: MariaDB → MongoDB
#  Steps: Clean → Extract → Load
# ============================================================
set -euo pipefail

JSONDIR="/var/lib/mysql-files"
DB="FurnitureDB"

echo "=============================="
echo " sync.sh started: $(date)"
echo "=============================="

echo "[1/3] CLEAN — Removing old JSON exports..."
rm -f "${JSONDIR}/prod.json" \
      "${JSONDIR}/cust.json" \
      "${JSONDIR}/custom1.json" \
      "${JSONDIR}/custom2.json"
echo "      Done."

echo "[2/3] EXTRACT — Running json.sql to generate fresh NDJSON..."
mariadb < /home/mbennett/json.sql
echo "      Done."

echo "[3/3] LOAD — Importing into MongoDB (${DB})..."
mongoimport --db "${DB}" --collection Products  --file "${JSONDIR}/prod.json"    --drop
mongoimport --db "${DB}" --collection Customers --file "${JSONDIR}/cust.json"    --drop
mongoimport --db "${DB}" --collection RegionalRevenue --file "${JSONDIR}/custom1.json" --drop
mongoimport --db "${DB}" --collection CustomerLTV     --file "${JSONDIR}/custom2.json" --drop
echo "      All collections imported."

echo "=============================="
echo " sync.sh complete: $(date)"
echo "=============================="
SYNCEOF

chown mbennett:mbennett /home/mbennett/sync.sh
chmod 755 /home/mbennett/sync.sh
LogStatus "sync.sh written"

LogStatus "Running initial sync.sh to populate MongoDB"
bash /home/mbennett/sync.sh
LogStatus "Initial MongoDB load complete"

LogStatus "Scheduling sync.sh via cron (every 5 minutes, run as root)"
# Write cron entry to /etc/cron.d so it survives reboots and runs as root
cat > /etc/cron.d/furniture-sync << 'CRONEOF'
# ISTM 622 M7 — sync MariaDB exports into MongoDB every 5 minutes
*/5 * * * * root bash /home/mbennett/sync.sh >> /var/log/sync.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/furniture-sync
LogStatus "Cron job scheduled (every 5 minutes)"

echo ""
echo "===================================================================="
echo "  M7 deployment complete."
echo "  MariaDB + MongoDB pipeline ready."
echo "  Collections in FurnitureDB:"
mongosh --quiet --eval "
  use('FurnitureDB');
  print('  Products:       ' + db.Products.countDocuments());
  print('  Customers:      ' + db.Customers.countDocuments());
  print('  RegionalRevenue:' + db.RegionalRevenue.countDocuments());
  print('  CustomerLTV:    ' + db.CustomerLTV.countDocuments());
" 2>/dev/null || echo "  (mongosh count skipped — check manually)"
echo "===================================================================="

ALTER TABLE FactTicketSales
ADD 
    accm_txn_create_time DATETIME,
    accm_txn_complete_time DATETIME,
    txn_process_time_hours FLOAT;
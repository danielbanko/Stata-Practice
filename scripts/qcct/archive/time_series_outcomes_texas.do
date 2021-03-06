cap log close
clear all
set more off
set trace off
set scheme cfpb
pause on

local projectpath 	/home/work/projects/Experian/Shared/ricksj/qcct_nov2018

log using `projectpath'/log/time_series_outcomes.txt, replace text

local CCPData 		/home/data/projects/Experian/ProcessedData/Stata
local ScoreVars 	consumer_nb vantage_sc deceased_cd
local TradeVars 	balance_dt consumer_nb ptk_nb kob_cd accounttype_cd balance_am balance_dt company_nb subscriber_nb status_cd estatus_cd condition_cd comment_cd ecoa_cd limit_am paymentgrid paymentgrid_cd open_dt actualpayment_am lastpayment_dt //added lastpayment_dt and status_cd

/***/
//NEED TO ADD 2018 DATA
*read in geography file, 48201 = Harris County FIPS code, 48113 = Dallas County FIPS code:
//	use consumer_nb tract using `CCPData'/geography.sample.sep2017.dta if inlist(floor(tract/1000000),48201,48113), clear
	use consumer_nb tract using `CCPData'/geography.sample.sep2017.dta if inlist(floor(tract/1000000),48201), clear
	format tract %16.0g
	gen county = floor(tract/1000000)

*merge in score file:
	merge 1:m consumer_nb using `CCPData'/score.sample.sep2017.dta, keep(match) keepusing(`ScoreVars') nogen
	drop if deceased_cd==1
	drop deceased_cd
	drop if vantage_sc<300 | vantage_sc>850

	tempfile consumer_data
	save `consumer_data', replace

* merge in tradeline files:
	foreach month in jan feb mar apr may jun jul aug sep oct nov dec {
		use `consumer_data', clear
		gen ReportingPeriod = "2017`month'"

		merge 1:m consumer_nb using `CCPData'/tradeline.sample.`month'2017.dta, keep(match) keepusing(`TradeVars') nogen

	*Weight each observation based on its ecoa code:
		gen ecoa_wt = 1 if inlist(ecoa_cd,"0","1","X","A","H","W","I")
		replace ecoa_wt = 0.5 if inlist(ecoa_cd,"2","B","4","D","5","E")
		replace ecoa_wt = 0.5 if inlist(ecoa_cd,"6","F","7","G")
		replace ecoa_wt = 0 if inlist(ecoa_cd,"3","C","NA")

		bysort consumer_nb ptk_nb ReportingPeriod: gen dup = _N
		replace ecoa_wt=ecoa_wt/dup
		
		drop if ecoa_wt==0

	*Determine which accounts are open and have been reported in the last 6 months:
		gen numArchive_dt = mofd(date(ReportingPeriod, "YM"))
		format numArchive_dt %tm
		gen numReported_dt = mofd(balance_dt)
		format numReported_dt %tm

		gen periods_since_reported = numArchive_dt  - numReported_dt

		keep if inlist(upper(condition_cd), "A1", "10") & periods_since_reported <= 5
		drop numReported_dt numArchive_dt

	*Generate loan type code:
		get_loan_type accounttype_cd kob_cd

	*calculate total balances of different types:
		gen balance_wt = balance_am * ecoa_wt
		gen cc_debt = balance_wt if loan_type==200
		gen student_debt = balance_wt if loan_type==150
		gen auto_debt = balance_wt if loan_type==100
//		gen mortgage_debt = balance_wt if loan_type==110 
		gen mortgage_debt = balance_wt if accounttype_cd == "26" //we want to use accounttype_cd == "26" instead of loan_type because restricts to PPM and first-lien mortgage only
		gen HELOC_debt = balance_wt if inlist(loan_type,120,220)
		gen other_debt = balance_wt if !inlist(loan_type,200,150,100,110,120,220)

		tempfile cohort_`month'2017
		save `cohort_`month'2017', replace
	}
	clear
	append using 	`cohort_jan2017' 		///
					`cohort_feb2017' 		///
					`cohort_mar2017' 		///
					`cohort_apr2017'		///
					`cohort_may2017'		///
					`cohort_jun2017'		///
					`cohort_jul2017'		///
					`cohort_aug2017'		///
					`cohort_sep2017'		///
					`cohort_oct2017'		///
					`cohort_nov2017'		///
					`cohort_dec2017'

	save `projectpath'/data/Houston_cohort_2017.dta, replace
***/
	use `projectpath'/data/Houston_cohort_2017.dta, clear
/***
	tab loan_type

	gen refinanced_mortgage = .
	replace refinanced_mortgage = 1 if accounttype_cd == "26" & status_cd == "10"
//for refinanced loans, which have status_cd == "10", the majority are student loans or unsecured loans. Need to be restricted to accounttype_cd == "26" refinanced mortgage

*Flags:
	gen over_limit = 0
	replace over_limit = 1 if balance_wt > limit_am
	
*Generate outcome measures:
	gen Month = month(date(substr(ReportingPeriod,5,3),"M"))
	gen credit_utilization = balance_wt/limit_am*100 if balance_wt > 0 & inlist(loan_type,120,200,220,230,240)
	gen mortgage_utilization = mortgage_debt/limit_am*100 if balance_wt > 0
	gen delinquency_dummy = 0
	replace delinquency_dummy = 1 if inlist(estatus_cd,"71","72","73","74","75","76","77","78","79")
	replace delinquency_dummy = 1 if inlist(estatus_cd,"80","81","82","83","84")
	
*Declare temp variables:
	tempvar cc_mean mortgage_mean sc_mean del_mean cc_median mortgage_median sc_median 
	tempvar credit_lines_by_month credit_lines_by_month_by_type morts_by_month cards_by_month autloans_by_month stuloans_by_month perloans_by_month retloans_by_month 
	tempvar tagcre tagmor tagaut tagper tagret tagtot
	
*Generate means:
	egen `cc_mean' = mean(credit_utilization) if loan_type==200, by(Month)
	egen `mortgage_mean' = mean(mortgage_utilization) if accounttype_cd == "26", by(Month)
	egen `sc_mean' = mean(vantage_sc), by(Month)
	egen `del_mean' = mean(delinquency_dummy), by(Month)

*Generate medians:
	egen `cc_median' = median(credit_utilization) if loan_type==200, by(Month)
	egen `mortgage_median' = median(mortgage_utilization) if accounttype_cd == "26", by(Month)
	egen `sc_median' = median(vantage_sc), by(Month)

*Generate totals:
	bysort Month: egen `credit_lines_by_month' = count(loan_type)
	bysort Month loan_type: egen `credit_lines_by_month_by_type' = count(loan_type)
	replace `credit_lines_by_month' = `credit_lines_by_month'/1000
	replace `credit_lines_by_month_by_type' = `credit_lines_by_month_by_type'/1000
 	table loan_type Month, c(n `credit_lines_by_month_by_type') row
	
*Generate totals by type:
	gen `morts_by_month' 	= `credit_lines_by_month_by_type' if accounttype_cd == "26"
	gen `cards_by_month' 	= `credit_lines_by_month_by_type' if loan_type==200
	gen `autloans_by_month' = `credit_lines_by_month_by_type' if loan_type==100
	gen `perloans_by_month' = `credit_lines_by_month_by_type' if loan_type==130
	gen `retloans_by_month' = `credit_lines_by_month_by_type' if loan_type==240

*Generate tags:
	egen `tagcre' = tag(Month) if loan_type==200 					
	egen `tagmor' = tag(Month) if accounttype_cd == "26"			
	egen `tagaut' = tag(Month) if loan_type==100					
	egen `tagper' = tag(Month) if loan_type==130										
	egen `tagret' = tag(Month) if loan_type==240					
	egen `tagtot' = tag(Month)							

*Create time series graphs:	
	twoway 	(scatter `mortgage_mean' Month if `tagmor',																				///
			connect(direct) 																										///
			sort(Month) 																											///									
		)																															///
		(scatter `mortgage_median' Month if `tagmor',																				///
			connect(direct) 																										///
			sort(Month)																												///
			title("Mortgage utilization")																							///
			ytitle("Mortgage utilization (%)") 																						///																											///
			xline(8) 																												///
			xla(1 "Jan" 2 "Feb" 3 "Mar" 4 "Apr" 5 "May" 6 "Jun" 7 "Jul" 8 "Aug" 9 "Sep" 10 "Oct" 11 "Nov" 12 "Dec")					///
			xtick(1(1)12)																											/// 																										///																											///
			legend(order(1 "Mean" 2 "Median"))																						///
		)																			
	graph export `projectpath'/figures/houston_mortgage_utilization_2017.png, replace


	twoway 	(scatter `cc_mean' Month if `tagcre',																					///
			connect(direct) 																										///
			sort(Month) 																											///
		)																															///
		(scatter `cc_median' Month if `tagcre',																						///	
			connect(direct) 																										///
			sort(Month) 																											///
			title("Credit card utilization")																						///
			ytitle("Credit card utilization (%)") 																					/// 																											///
			xline(8) 																												///
			xla(1 "Jan" 2 "Feb" 3 "Mar" 4 "Apr" 5 "May" 6 "Jun" 7 "Jul" 8 "Aug" 9 "Sep" 10 "Oct" 11 "Nov" 12 "Dec")					///
			xtick(1(1)12)																											/// 																										///
			ymtick(#100)																											///
			legend(order(1 "Mean" 2 "Median"))																						///
		)
	graph export `projectpath'/figures/houston_creditcard_utilization_2017.png, replace
	
	
	twoway (scatter `sc_mean' Month if `tagtot', 																					///
			connect(direct) 																										///
			sort(Month)																												///
		) 																															///
		(scatter `sc_median' Month if `tagtot', 																					///
			connect(direct) 																										///
			sort(Month) 																											///
			title("Average credit score")																							///
			ytitle("Average credit score (points)") 																				/// 																										///
			xline(8) 																												///
			xla(1 "Jan" 2 "Feb" 3 "Mar" 4 "Apr" 5 "May" 6 "Jun" 7 "Jul" 8 "Aug" 9 "Sep" 10 "Oct" 11 "Nov" 12 "Dec") 				///
			xtick(1(1)12)																											/// 																										///																											///
			legend(order(1 "Mean score" 2 "Median score"))																			///
		)
	graph export `projectpath'/figures/houston_avg_credit_score_2017.png, replace


	scatter `del_mean' Month if `tagtot', 																							///
		connect(direct) 																											///
		sort(Month) 																												///
		title("Portion of payments delinquent")																						///
		ytitle("Portion of payments delinquent") 																					/// 																												///
		xline(8) 																													///
		xla(1 "Jan" 2 "Feb" 3 "Mar" 4 "Apr" 5 "May" 6 "Jun" 7 "Jul" 8 "Aug" 9 "Sep" 10 "Oct" 11 "Nov" 12 "Dec") 					///
		xtick(1(1)12)																												///																											///
		ymtick(#100)																	
	graph export `projectpath'/figures/houston_delinquency_rate_2017.png, replace


twoway 	(																															///
		scatter `credit_lines_by_month' Month if `tagtot',																			///
			connect(direct) 																										///
			sort(Month) 																											///
		)																															///
																																	///
		(																															///
		scatter `morts_by_month' Month if `tagmor',																					///
			connect(direct) 																										///
			sort(Month) 																											///											
		)																															///					
																																	///																			
		(																															///
		scatter `cards_by_month' Month if `tagcre',																					///
			connect(direct) 																										///
			sort(Month) 																											///
		)																															///
																																	///																	
		(																															///
		scatter `autloans_by_month' Month if `tagaut',																				///
			connect(direct) 																										///
			sort(Month) 																											///											
		)																															///
																																	///
		(																															///
		scatter `perloans_by_month' Month if `tagper',																				///
			connect(direct) 																										///
			sort(Month) 																											///							
		)																															///
																																	///
		(																															///
		scatter `retloans_by_month' Month if `tagret',																				///
			connect(direct) 																										///
			sort(Month) 																											///
			title("Total loans")																									///
			ytitle("# of loans (in thousands)") 																					/// 																											///
			xline(8) 																												///
			xla(1 "Jan" 2 "Feb" 3 "Mar" 4 "Apr" 5 "May" 6 "Jun" 7 "Jul" 8 "Aug" 9 "Sep" 10 "Oct" 11 "Nov" 12 "Dec")					///
			xtick(1(1)12)																											/// 																										///																											///
			legend(order(1 "Total" 2 "First-lien PMM and refi mortgages" 3 "Credit cards" 4 "Auto loans" 5 "Personal loans" 6 "Retail loans"))				///									
		)

	graph export `projectpath'/figures/houston_credit_lines_2017.png, replace
**/	
	shell echo -e "It's Done" | mail -s "STATA finished" "daniel.banko-ferran@cfpb.gov"

	log close
	

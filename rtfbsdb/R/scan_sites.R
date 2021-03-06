##
## find_sites_rtfbs.R
##
## Finds PWMs in DNAse-1 peaks using rtfbs package availiable on CRAN.
##

#' Extend BED file
#'
#' @param bed data.frame with bed regions
#' @param len extension in bp
#' @return extended bed data.frame

extend.bed <- function( bed, len, file.twoBit )
{
	chr_info <- get_chromosome_size( file.twoBit );
	chr_max  <- chr_info[ match( bed[,1], chr_info[,1]), 2 ];

	# if remove some loci which fall outside the chromosome range.
	if(length(which( bed[,2] > chr_max) ) >0 )
	{
		idx.abnormal <- which( bed[,2] > chr_max );
		loci.abnormal <- paste(bed[idx.abnormal,1],":", bed[idx.abnormal,2],"-",bed[idx.abnormal,3], sep="");
		warning( paste( "Some loci fall outside the chromosome range. (e.g. ", paste(head(loci.abnormal), collapse =",", se=""), ")" ) );

		## remove  the loci which fall outside.
		bed <- bed[ -idx.abnormal, ];
		chr_max <- chr_max [ -idx.abnormal ];
	}

	starts = as.integer(bed[,2] - len);
	ends   = as.integer(bed[,3] + len);
	chr    = bed[,1];

	ends[ ends >  chr_max ] <- chr_max[ ends >  chr_max ];
	starts[ starts <=1 ] <- 1;

	N = NCOL(bed);
	if (N == 3) {
		data.frame(bed[,1], starts, ends)
	} else {
		data.frame(bed[,1], starts, ends, bed[, 4:N])
	}
}

#` Returns the posterior probability of TF binding, conditional on the data passed as part of the function.
#`
#` Optionally takes additional parameters passed through to score.ms.
#`
#` @param tf_name name of the TF.
#` @param gen.bed bed-formatted peak information.
#` @param motif_path path to the motif PWM file.
#` @param divide_num List of parameters for all data types, for the model representing no TF binding.
#` @return List structure representing the match score to the motif.

scan_rtfbs <- function( tf_name, file.twoBit, gen.bed, motif_path, return.posteriors=TRUE, ...)
{
	## Read the pwm and sequence file.
	motif <- read.motif(motif_path, header=TRUE)

	## Write out new fasta file, adding on half-width of the motif, to correctly align motif center ...
	half_width <- ceiling( (NROW(motif)-1)/2 );
	extBed = extend.bed( gen.bed, half_width - 1, file.twoBit );
	dnase_peaks = read.seqfile.from.bed( extBed, file.twoBit,rm.dup=FALSE );

	## Swiched rtfbs to returning posteriors.
	bgModel <- build.mm(dnase_peaks, 3);

	## Switch to rtfbsPost to return proper data structure.
	binding <- score.ms(dnase_peaks, motif, bgModel, return_posteriors=return.posteriors, ...) ;

	## Parse binding site into genomic coordinates.
	if(return.posteriors == FALSE)
	{
		spl <- strsplit(as.character(binding$seqname), ":|-")
		peak_chrom <- as.character(sapply(c(1:NROW(binding)), function(x) {spl[[x]][[1]]}))
		peak_start <- as.integer(sapply(c(1:NROW(binding)), function(x) {spl[[x]][[2]]}))
		binding <- data.frame(  chrom      = peak_chrom,
								chromStart = peak_start+ binding$start,
								chromEnd   = peak_start+ binding$end,
								name       = binding$seqname,
								score      = binding$score,
								strand     = binding$strand);
	}

	return(binding);
}

get_binding_site <- function( bgModel1,
							seq.ms,
							PWM,
							return.posteriors,
							score.threshold = 6,
							fdr.threshold = NA,
							gc.groups = NA,
							background.order = 2,
							background.length = 100000)
{
	if ( is.na(score.threshold) &&  is.na(fdr.threshold)) score.threshold <- 6;
	if (!is.na(score.threshold) && !is.na(fdr.threshold)) score.threshold <- NA;

	if( is.na( gc.groups) )
	{
		if(is.na(fdr.threshold))
			binding <- score.ms( seq.ms, PWM, bgModel1, return_posteriors=return.posteriors, threshold=score.threshold )
		else
		{
			seq.score <- score.ms( seq.ms, PWM, bgModel1, return_posteriors=return.posteriors, threshold=0 );
			simu.ms   <- simulate.ms( bgModel1, background.length );
			simu.score<- score.ms( simu.ms, PWM, bgModel1, threshold=0 );
			fdrMap    <- calc.fdr( seq.ms, seq.score, simu.ms, simu.score );
			binding   <- output.sites( seq.score, fdrScoreMap  = fdrMap, fdrThreshold = fdr.threshold);
		}
	}
	else
	{
		msGroups <- groupByGC.ms( seq.ms, gc.groups);

		bgModels <- lapply(1:length(msGroups),
						function(i) { build.mm(msGroups[[i]], background.order) } );

		seq.score <- lapply(1:length(msGroups),
						function(i) { score.ms(msGroups[[i]],
												PWM,
												bgModels[[i]],
												return_posteriors=return.posteriors,
												threshold=ifelse(!is.na(fdr.threshold), 0, score.threshold));});

		if(is.na(fdr.threshold))
		{
			binding <- do.call("rbind", seq.score);
		}
		else
		{
			simu.ms <- lapply( 1:length(msGroups),
							function(i){ simulate.ms(bgModels[[i]], background.length)});
			simu.score <- lapply( 1:length(msGroups),
							function(i){ score.ms(simu.ms[[i]], PWM, bgModels[[i]])});
			fdrMap  <- lapply( 1:length(msGroups),
							function(i) { calc.fdr(msGroups[[i]], seq.score[[i]], simu.ms[[i]], simu.score[[i]])});
			binding <- lapply( 1:length(msGroups),
							function(i) { output.sites(seq.score[[i]], fdrScoreMap  = fdrMap[[i]], fdrThreshold = fdr.threshold);} );

			binding <- do.call("rbind", binding);
		}

	}

	return( binding );
}

## return.type --> c("matches", "maxscore", "posteriors", "maxposterior", or "writedb")
##
## matches 		-- returns all matching motifs.
## writedb 		-- writes a bed file with matches.  Assuems that sort-bed and starch tools are availiable in $PATH
## posteriors 	-- returns the posteriors at each position.
## maxposterior	-- returns the max(posterior) in each dnase-1 peak.
## maxscore	    -- returns the max(score) in each dnase-1 peak.

scanDb_rtfbs <- function(tfbs,
						file.twoBit,
						gen.bed,
						return.type = "matches",
						file.prefix = NA,
						usemotifs = NA,
						ncores = 1,
						fdr.threshold = NA,
						score.threshold = 6,
						gc.groups = NA,
						background.order = 2,
						background.length = 100000,...)
{
	stopifnot(class(tfbs) == "tfbs")

	if( !is.na(file.prefix))
		if( !check_folder_writable( file.prefix ) )
			stop(paste("Can not create files starting with the prefix:", file.prefix));

	## Read in the DNAse-1 peaks ...
	half_width = 15 ## Max size of TF in set of 1800 is 30 (half-width = 15).
	options("scipen"=100, "digits"=4)

	extBed  <- extend.bed( gen.bed, half_width - 1, file.twoBit)
	##!!!!! Any invalid genomic loci in extBed will be removed by read.seqfile.from.bed(), so length(seq.ms) ==  or <> length(extBed).
	seq.ms  <- read.seqfile.from.bed( extBed, file.twoBit);
	bgModel <- build.mm( seq.ms, 3);

	## Swiched rtfbs to returning posteriors.
	return.posteriors <- ( return.type %in% c("posteriors", "maxposterior", "maxscore" ) );

get_binding_site <- function( bgModel1,
							seq.ms,
							PWM,
							return.posteriors,
							score.threshold = 6,
							fdr.threshold = NA,
							gc.groups = NA,
							background.order = 2,
							background.length = 100000)
{
	if ( is.na(score.threshold) &&  is.na(fdr.threshold)) score.threshold <- 6;
	if (!is.na(score.threshold) && !is.na(fdr.threshold)) score.threshold <- NA;

	if( is.na( gc.groups) )
	{
		if(is.na(fdr.threshold))
			binding <- score.ms( seq.ms, PWM, bgModel1, return_posteriors=return.posteriors, threshold=score.threshold )
		else
		{
			seq.score <- score.ms( seq.ms, PWM, bgModel1, return_posteriors=return.posteriors, threshold=0 );
			simu.ms   <- simulate.ms( bgModel1, background.length );
			simu.score<- score.ms( simu.ms, PWM, bgModel1, threshold=0 );
			fdrMap    <- calc.fdr( seq.ms, seq.score, simu.ms, simu.score );
			binding   <- output.sites( seq.score, fdrScoreMap  = fdrMap, fdrThreshold = fdr.threshold);
		}
	}
	else
	{
		msGroups <- groupByGC.ms( seq.ms, gc.groups);

		bgModels <- lapply(1:length(msGroups),
						function(i) { build.mm(msGroups[[i]], background.order) } );

		seq.score <- lapply(1:length(msGroups),
						function(i) { score.ms(msGroups[[i]],
												PWM,
												bgModels[[i]],
												return_posteriors=return.posteriors,
												threshold=ifelse(!is.na(fdr.threshold), 0, score.threshold));});

		if(is.na(fdr.threshold))
		{
			binding <- do.call("rbind", seq.score);
		}
		else
		{
			simu.ms <- lapply( 1:length(msGroups),
							function(i){ simulate.ms(bgModels[[i]], background.length)});
			simu.score <- lapply( 1:length(msGroups),
							function(i){ score.ms(simu.ms[[i]], PWM, bgModels[[i]])});
			fdrMap  <- lapply( 1:length(msGroups),
							function(i) { calc.fdr(msGroups[[i]], seq.score[[i]], simu.ms[[i]], simu.score[[i]])});
			binding <- lapply( 1:length(msGroups),
							function(i) { output.sites(seq.score[[i]], fdrScoreMap  = fdrMap[[i]], fdrThreshold = fdr.threshold);} );

			binding <- do.call("rbind", binding);
		}

	}

	return( binding );
}

	scan_each_motif <- function (i )
	{
		require(rtfbsdb);
		require(rtfbs);

		options("scipen"=100, "digits"=4)
		binding<- NULL;

		## Read the pwm and sequence file.
		PWM <- tfbs@pwm[[i]];

		## Parse binding site into genomic coordinates.
		if( return.posteriors )
		{
			binding <- score.ms( seq.ms, PWM, bgModel, return_posteriors=TRUE, threshold = score.threshold );

			if( is.null(binding) || NROW(binding) == 0 )
				return(NA);

			if( return.type == "maxscore" )
				return(sapply(1:NROW(binding), function(x) {
					max(c(binding[[x]]$MotifModel$Forward - binding[[x]]$Background, binding[[x]]$MotifModel$Reverse - binding[[x]]$Background)) }));

			if( return.type == "maxposterior" )
				return(sapply(1:NROW(binding), function(x) {
					max(c(binding[[x]]$MotifModel$Forward, binding[[x]]$MotifModel$Reverse )) }));
		}

		## Parse binding site into genomic coordinates.
		if(return.posteriors == FALSE )
		{
			binding <- get_binding_site( bgModel,
							seq.ms,
							PWM,
							FALSE,
							score.threshold = score.threshold,
							fdr.threshold = fdr.threshold,
							gc.groups = gc.groups,
							background.order = 2,
							background.length = 100000 );

			if( NROW(binding) > 0 )
			{
				spl <- strsplit(as.character(binding$seqname), ":|-")
				peak_chrom <- as.character(sapply(c(1:NROW(binding)), function(x) {spl[[x]][[1]]}))
				peak_start <- as.integer(sapply(c(1:NROW(binding)), function(x) {spl[[x]][[2]]}))
				peak_end <- as.integer(sapply(c(1:NROW(binding)), function(x) {spl[[x]][[3]]}))

				binding <- data.frame(  chrom      = peak_chrom,
										chromStart = peak_start+ binding$start- 1,  ## -1 determined empirically.
										chromEnd   = peak_start+ binding$end,
										name       = tfbs@mgisymbols[i], # binding$motif_id
										score      = binding$score,
										strand     = binding$strand,
										peakStart  = peak_start,
										peakEnd    = peak_end)

				if(return.type == "writedb") {
					file.starch <- paste(file.prefix,i,".bed.tmp.starch", sep="");
					write.starchbed(binding, file.starch);
					return(file.starch);
				}
			}
			else
				binding <- NULL;
		}

		return(binding);
	}

    if(ncores>1)
    {
   	    require(snowfall);
        sfInit(parallel = TRUE, cpus = ncores, type = "SOCK" )
        sfExport("tfbs", "seq.ms", "bgModel", "return.posteriors",
			"file.twoBit",
			"return.type",
			"file.prefix",
			"fdr.threshold",
			"score.threshold",
			"gc.groups",
			"background.order",
			"background.length",
			"get_binding_site");

        fun <- as.function(scan_each_motif);
        environment(fun)<-globalenv();

        binding_all <- sfLapply( usemotifs, fun);
	    sfStop();
    }
    else
        binding_all <- lapply( usemotifs, scan_each_motif);
    
	if(return.type == "writedb")
	{
		cat_files <- paste(unlist(binding_all), collapse=" ");
		final_starch <- paste(file.prefix,".db.starch", sep="");

		#err_code <- system(paste("starchcat ", cat_files, " > ", final_starch, sep=""));
		#system(paste("rm ",file.prefix,"*.bed.tmp.starch",sep=""))
		#if( err_code != 0 )
		#	warning("Failed to call the starchcat command to generate starch file.\n");

		err_code <- smallres_starchcat( unlist(binding_all), final_starch, ncores);
		binding_all <- final_starch;
	}

	if(return.type %in% c( "maxposterior", "maxscore") )
	{
		seqList <- unlist(lapply(seq.ms, function(ms) {ms[1]}));
		seqList.org <- paste(extBed[,1],":", as.integer(extBed[,2]), "-", as.integer(extBed[,3]), sep="");
		idx.bed <- match(seqList, seqList.org);

		binding_mat <- matrix(NA, nrow= NROW(extBed), ncol= NROW(usemotifs))
		binding_mat[idx.bed, ] <- matrix(unlist(binding_all), ncol= NROW(usemotifs));
		binding_all <- binding_mat;
	}

	return(binding_all)
}


smallres_starchcat<-function( starch.files, final.starch, ncores)
{
    reduce4<-function(mfiles4)
    {
		L <- mclapply( 1:ceiling(NROW(mfiles4)/4), function(i)
			{
			    tempf <- tempfile(fileext=".starch");
			    temp0 <- starch.files[ (i-1)*4+c(1:4) ];
			    temp0 <- temp0[!is.na(temp0)];
				err_code <- system(paste("starchcat ", paste(temp0, collapse=" "), " > ", tempf));		
				if( err_code != 0 )
					warning("Failed to call the starchcat command to generate starch file.\n");
		         
				unlink(temp0);
		        return(tempf);
			}, mc.cores=ncores);
		return(unlist(L));	
	}
	
	while( NROW(starch.files)>1 )
	{
		starch.files <- reduce4(starch.files);
	}

	err_code <- system(paste("cp", starch.files, final.starch));
	unlink(starch.files);
	return(0);
}

# ncores=3 for 4 cores CPU.

tfbs_scanTFsite <- function( tfbs, file.genome,
							gen.bed = NULL,
							return.type="matches",
							file.prefix = NA,
							usemotifs = NA,
							ncores = 1,
							threshold = 6,
							threshold.type = c("score", "fdr"),
							gc.groups = NA,
							background.order = 2,
							background.length = 100000,
							exclude_offset = 250,
							exclude_chromosome="_|chrM|chrY|chrX" )
{
	stopifnot(class(tfbs) == "tfbs")
	stopifnot(return.type %in% c("matches", "maxscore", "posteriors", "maxposterior", "writedb") );

	if( !file.exists (file.genome)  )
		stop(paste("Genome file is not accessible, File=", file.genome));

	file.twoBit = file.genome;
	if( tolower( file_ext( file.genome ) ) != "2bit" )
	{
		file.twoBit = tempfile(fileext=".2bit")

		# generate fasta file
		err_code <- system(paste("faToTwoBit ", file.genome, " ", file.twoBit), wait = TRUE);
		if( err_code != 0 || !file.exists (file.twoBit) )
			stop("Failed to call faToTwoBit to convert FASTFA file.");
	}

	if( missing(gen.bed) && (return.type %in% c("posteriors", "maxposterior", "maxscore")) )
		stop("The option 'maxscore', 'posteriors' or 'maxposterior' need specified genomic loci.");

	if( missing(gen.bed) || is.null(gen.bed) )
	{
		chromInfo <- get_chromosome_size( file.twoBit );

		if( !is.null( exclude_chromosome ) && !is.na(exclude_chromosome) )
			chromInfo <- chromInfo[grep( exclude_chromosome , chromInfo[,1], invert=TRUE),];

		#exclude_offset <- 250;
		if( is.na( exclude_offset ) )
			exclude_offset <- 0;

		gen.bed <- data.frame(chrom=chromInfo[,1], chromStart=rep(0)+exclude_offset, chromEnd=(chromInfo[,2]-1-exclude_offset));
	}
	else
		if( !check_bed(gen.bed) )
			stop("Wrong format in the parameter of 'gen.bed', at least three columns including chromosome, strat, stop.");

	if( missing(usemotifs)) usemotifs =c(1:tfbs@ntfs);
	if( missing(file.prefix) ) file.prefix="scan.db";
	if( missing(return.type) ) return.type="matches";
	if( missing(ncores) ) ncores= 1;

	score.threshold <- NA;
	fdr.threshold   <- NA;
	if( missing( threshold.type ) ) threshold.type <- "score";
	if( threshold.type == "score" )
		if( missing( threshold ) )
			score.threshold <- 6
		else
			score.threshold <- threshold ;

	if( threshold.type == "fdr" )
		if( missing( threshold ) )
			fdr.threshold <- 0.1
		else
			fdr.threshold <- threshold ;

	r.ret <- scanDb_rtfbs( tfbs, file.twoBit,
					gen.bed,
					file.prefix      = file.prefix,
					return.type      = return.type,
					usemotifs        = usemotifs,
					ncores           = ncores,
					fdr.threshold    = fdr.threshold,
					score.threshold  = score.threshold,
					gc.groups        = gc.groups,
					background.order = background.order,
					background.length = background.length );

	r.parm <- list(file.genome       = file.genome,
					file.prefix      = file.prefix,
					return.type      = return.type,
					usemotifs        = usemotifs,
					ncores           = ncores,
					gc.groups        = gc.groups,
					threshold        = ifelse(threshold.type=="score", score.threshold, fdr.threshold ),
					threshold.type   = threshold.type,
					background.order = background.order,
					background.length = background.length);

	sum.match <- data.frame(
					Motif_ID = tfbs@tf_info$Motif_ID[ usemotifs ],
					TF_Name  = tfbs@tf_info$TF_Name[  usemotifs ] );

	if( return.type == "matches" )
	{
		sum.match <- do.call("rbind", lapply( 1:length(usemotifs), function(i){

				x <- r.ret[[i]];
				motif.id <- as.character( tfbs@tf_info$Motif_ID[ usemotifs[i] ] );
				tf.name  <- as.character( tfbs@tf_info$TF_Name[  usemotifs[i] ] );

				if (NROW(x)==0) return( data.frame( motif.id, tf.name, count=0 ) );

				stopifnot( as.character( x$name[1] ) == motif.id );

				return( data.frame(motif.id, tf.name, count=NROW(x) ) );
		} ) );

		colnames(sum.match) <- c("Motif_ID", "TF_Name", "Count");
	}

	if( return.type %in% c("maxposterior", "maxscore") )
	{
		sum.match <- data.frame(
					tfbs@tf_info$Motif_ID[ usemotifs ],
					tfbs@tf_info$TF_Name[ usemotifs ],
					colMeans( r.ret, na.rm=T) );

		colnames(sum.match) <- c("Motif_ID", "TF_Name", "Mean" );
	}

	r.scan <- list( parm = r.parm, bed = gen.bed, result = r.ret, summary=sum.match );
	class( r.scan ) <- c( "tfbs.finding" );

	return( r.scan );
}

print.tfbs.finding<-function(x, ...)
{
	r.scan <- x;

	cat("Return type: ", r.scan$parm$return.type, "\n");
	if(r.scan$parm$return.type %in% c("matches", "writedb") )
	{
		cat("Threshold Type: ", r.scan$parm$threshold.type, "\n");
		cat("Threshold: ",   r.scan$parm$threshold, "\n");
	}

	if( r.scan$parm$return.type == "matches" )
	{
		df.allfinding <- do.call("rbind", r.scan$result );
		cat("Motifs count: ", length(r.scan$result), "\n");
		cat("Binding sites: ", NROW(df.allfinding), "\n");

		summary <- r.scan$summary[order(r.scan$summary[,3], decreasing = TRUE ),];
		if( NROW( summary )>20)
			summary <- summary[c(1:20),];
		show( summary );
	}

	if( r.scan$parm$return.type == "writedb" )
		cat("Binary Bed file: ", r.scan$result, "\n");

	if( r.scan$parm$return.type == "posteriors" )
	{
		df.allfinding <- do.call("rbind", r.scan$result );
		cat("Motifs count: ", length(r.scan$result), "\n");
		cat("Binding sites: ", NROW(df.allfinding), "\n");
	}

	if(r.scan$parm$return.type %in% c("maxposterior", "maxscore") )
		cat("Matrix posterior: ", NROW(r.scan$result), "*", NCOL(r.scan$result), "\n");
}

summary.tfbs.finding<-function( object, ... )
{
	r.scan <- object;

	if( r.scan$parm$return.type == "matches" )
		return( r.scan$summary )
	else
		return(NULL);
}

tfbs.reportFinding<-function( tfbs, r.scan, file.pdf = NA, report.size = "letter", report.title = "" )
{
	stopifnot(class(tfbs) == "tfbs" && class(r.scan) == "tfbs.finding")

	if( !is.null(file.pdf) && !is.na(file.pdf) )
		if( !check_folder_writable( file.pdf ) )
			stop( paste("Can not create pdf file: ",file.pdf ) );

	if( r.scan$parm$return.type != "matches" )
		cat( "! No summary information for the report.\n" )
	else
	{
		summary <- r.scan$summary[order(r.scan$summary[,3], decreasing = TRUE ),];

		r.scan.sum <- data.frame( No=c(1:NROW(summary)), summary, summary[,1] );

		df.style <- data.frame( position = numeric(0),
								width    = numeric(0),
								header   = character(0),
								hjust    = character(0),
								style    = character(0),
								extra1   = character(0),
								extra2   = character(0),
								extra3   = character(0),
								extra4   = character(0));
		df.style <- rbind( df.style,
					data.frame( position = 0.00,
								width    = 0.04,
								header   = "No.",
								hjust    = "left",
								style    = "text",
								extra1   = "0",
								extra2   = "0",
								extra3   = "0",
								extra4   = "0") );
		df.style <- rbind( df.style,
					data.frame( position = 0.04,
								width    = 0.10,
								header   = "Motif ID",
								hjust    = "left",
								style    = "text",
								extra1   = "0",
								extra2   = "0",
								extra3   = "0",
								extra4   = "0") );
		df.style <- rbind( df.style,
					data.frame( position = 0.14,
								width    = 0.10,
								header   = "TF Name",
								hjust    = "left",
								style    = "text",
								extra1   = "0",
								extra2   = "0",
								extra3   = "0",
								extra4   = "0") );
		df.style <- rbind( df.style,
					data.frame( position = 0.24,
								width    = 0.10,
								header   = "Count",
								hjust    = "centre",
								style    = "text",
								extra1   = "0",
								extra2   = "0",
								extra3   = "0",
								extra4   = "0") );
		df.style <- rbind( df.style,
					data.frame( position = 0.34,
								width    = 0.49,
								header   = "Motif Logo",
								hjust    = "centre",
								style    = "logo",
								extra1   = "0",
								extra2   = "0",
								extra3   = "0",
								extra4   = "0") );

		output_motif_report( tfbs, r.scan.sum, file.pdf, report.size, report.title, df.style );
	}
}


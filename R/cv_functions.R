## function for the ensemble predictions for Cross Validation (runs in parallel hence can be run on large data sets)
## by: Tom.Hengl@isric.org, Gerard.Heuvelink@wur.nl and Maria.RuiperezGonzales@wur.nl

list.of.packages <- c("nnet", "plyr", "ROCR", "randomForest", "plyr", "parallel", "psych", "mda", "h2o", "dismo", "grDevices", "snowfall", "hexbin", "lattice", "ranger", "xgboost", "doParallel", "caret")
new.packages <- list.of.packages[!(list.of.packages %in% installed.packages()[,"Package"])]
if(length(new.packages)) install.packages(new.packages)

## --------------------------------------------------------------
## Classes:
## --------------------------------------------------------------

## prediction error for predicting probs:
cv_factor <- function(formulaString, rmatrix, nfold, idcol, cpus=nfold){ 
  varn <- all.vars(formulaString)[1]
  sel <- dismo::kfold(rmatrix, k=nfold, by=rmatrix[,varn])
  message(paste("Running ", nfold, "-fold cross validation with model re-fitting...", sep=""))
  ## run in parallel:
  if(missing(cpus)){ 
    cpus <- parallel::detectCores(all.tests = FALSE, logical = FALSE) 
  }
  snowfall::sfInit(parallel=TRUE, cpus=cpus)
  snowfall::sfExport("ensemble.predict","idcol","formulaString","rmatrix","sel","varn","predict_parallel")
  snowfall::sfLibrary(package="ROCR", character.only=TRUE)
  snowfall::sfLibrary(package="nnet", character.only=TRUE)
  snowfall::sfLibrary(package="plyr", character.only=TRUE)
  snowfall::sfLibrary(package="ranger", character.only=TRUE)
  snowfall::sfLibrary(package="caret", character.only=TRUE)
  out <- snowfall::sfLapply(1:nfold, function(j){predict_parallel(j, sel=sel, varn=varn, formulaString=formulaString, rmatrix=rmatrix, idcol=idcol)})
  snowfall::sfStop()
  ## calculate totals per soil type
  N.tot <- plyr::rbind.fill(lapply(out, function(x){x[["n.l"]]}))
  N.tot <- colSums(N.tot)
  ## mean error per soil type:
  mean.error <- plyr::rbind.fill(lapply(out, function(x){x[["error.l"]]}))
  mean.error <- colSums(mean.error)/N.tot
  error <- plyr::rbind.fill(lapply(out, function(x){x[["error"]]}))
  obs <- plyr::rbind.fill(lapply(out, function(x){ as.data.frame(x[["obs.pred"]][[1]])}))
  pred <- plyr::rbind.fill(lapply(out, function(x){ as.data.frame(x[["obs.pred"]][[2]])}))
  ## Get the most probable class:
  cl <- parallel::makeCluster(getOption("cl.cores", cpus))
  ranks.pred <- parallel::parApply(cl, pred, MARGIN=1, which.max)
  ranks.obs <- parallel::parApply(cl, obs, MARGIN=1, which.max)
  parallel::stopCluster(cl)
  ## derive confusion matrix:
  cf <- mda::confusion(names(obs)[ranks.obs], names(pred)[ranks.pred])
  c.kappa <- psych::cohen.kappa(cbind(names(obs)[ranks.obs], names(pred)[ranks.pred]))
  purity <- sum(diag(cf))/sum(cf)*100  
  ## Accuracy for Binomial var [http://www.r-bloggers.com/evaluating-logistic-regression-models/]: 
  TPR <- sapply(1:ncol(obs), function(c){mean(performance( prediction(pred[,c], obs[,c]), measure="tpr")@y.values[[1]])})
  AUC <- sapply(1:ncol(obs), function(c){performance( prediction(pred[,c], obs[,c]), measure="auc")@y.values[[1]]})
  cv.r <- list(obs, pred, error, data.frame(ME=mean.error, TPR=TPR, AUC=AUC, N=N.tot), cf, c.kappa, purity)
  names(cv.r) <- c("Observed", "Predicted", "CV_residuals", "Classes", "Confusion.matrix", "Cohen.Kappa", "Purity")
  return(cv.r)
}

## factor-type vars:
ensemble.predict <- function(formulaString, s.train, s.test, MaxNWts = 19000, ...){ 
  ## drop empty levels to avoid errors:
  s.train[,all.vars(formulaString)[1]] <- droplevels(s.train[,all.vars(formulaString)[1]])
  gm1 <- nnet::multinom(formulaString, data=s.train, MaxNWts = MaxNWts)
  ## derive classification accuracy:
  gm1.w <- postResample(s.train[,all.vars(formulaString)[1]], predict(gm1, s.train, na.action = na.pass))[1]
  gm2 <- ranger::ranger(formulaString, data=s.train, write.forest=TRUE, probability=TRUE, ...)
  gm2.w <- 1-gm2$prediction.error
  probs1 <- predict(gm1, s.test, type="probs", na.action = na.pass) ## nnet
  probs2 <- predict(gm2, s.test, probability=TRUE, na.action = na.pass)$predictions ## randomForest
  ## weighted mean:
  lt <- list(probs1[,gm1$lev]*gm1.w, probs2[,gm1$lev]*gm2.w)
  probs <- Reduce("+", lt) / rep(gm1.w+gm2.w, length(probs1))
  return(probs)
}

## ensemble prediction in parallel (for parallelization):
predict_parallel <- function(j, sel, varn, formulaString, rmatrix, idcol){
  s.train <- rmatrix[!sel==j,]
  s.test <- rmatrix[sel==j,]
  n.l <- plyr::count(s.test[,varn])
  n.l <- data.frame(matrix(n.l$freq, nrow=1, dimnames = list(1, paste(n.l$x))))
  probs <- ensemble.predict(formulaString=formulaString, s.train=s.train, s.test=s.test)
  names <- colnames(probs)
  obs <- data.frame(lapply(names, FUN=function(i){ifelse(s.test[, varn]==i, 1, 0)}))
  names(obs) = names
  obs.pred <- list(as.matrix(obs[,names]), probs[,names])
  error <- Reduce("-", obs.pred)
  error.l <- as.data.frame(t(signif(colSums(error), 3)))
  ## copy ID of the point
  error <- as.data.frame(error)
  error[,idcol] <- paste(s.test[,idcol])
  ## Accuracy for Binomial var [http://www.r-bloggers.com/evaluating-logistic-regression-models/]:
  pred.l <- lapply(1:nrow(obs.pred[[2]]), function(i){prediction(obs.pred[[2]][i,], obs.pred[[1]][i,])})
  out <- list(n.l, obs.pred, error, error.l)
  names(out) <- c("n.l", "obs.pred", "error", "error.l")
  return(out)
}

## --------------------------------------------------------------
## Properties:
## --------------------------------------------------------------

## predict soil properties in parallel:
predict_parallelP <- function(j, sel, varn, formulaString, rmatrix, idcol, method, cpus, Nsub=1e4, remove_duplicates=FALSE){
	message(paste0("Starting predict_parallelP with method: ", method))
  s.train <- rmatrix[!sel==j,]
  if(remove_duplicates==TRUE){
    ## TH: optional - check how does model performs without the knowledge of the 3D dimension
    sel.dup = !duplicated(s.train[,idcol])
    s.train <- s.train[sel.dup,]
  }
  s.test <- rmatrix[sel==j,]
  n.l <- dim(s.test)[1]
  if(missing(Nsub)){ Nsub = length(all.vars(formulaString))*50 }
  if(Nsub>nrow(s.train)){ Nsub = nrow(s.train) }
  if(method=="h2o"){
    ## select only complete point pairs
    train.hex <- as.h2o(s.train[complete.cases(s.train[,all.vars(formulaString)]),all.vars(formulaString)], destination_frame = "train.hex")
    gm1 <- h2o.randomForest(y=1, x=2:length(all.vars(formulaString)), training_frame=train.hex) 
    gm2 <- h2o.deeplearning(y=1, x=2:length(all.vars(formulaString)), training_frame=train.hex)
    test.hex <- as.h2o(s.test[,all.vars(formulaString)], destination_frame = "test.hex")
    v1 <- as.data.frame(h2o.predict(gm1, test.hex, na.action=na.pass))$predict
    gm1.w = gm1@model$training_metrics@metrics$r2
    v2 <- as.data.frame(h2o.predict(gm2, test.hex, na.action=na.pass))$predict
    gm2.w = gm2@model$training_metrics@metrics$r2
    ## mean prediction based on accuracy:
    pred <- rowSums(cbind(v1*gm1.w, v2*gm2.w))/(gm1.w+gm2.w)
    gc()
    h2o.removeAll()
  }
  if(method=="caret"){
    test = s.test[,all.vars(formulaString)]
    ## tuning parameters:
    cl <- parallel::makeCluster(cpus)
	doParallel::registerDoParallel(cl)
    ctrl <- caret::trainControl(method="repeatedcv", number=3, repeats=1)
    gb.tuneGrid <- expand.grid(eta = c(0.3,0.4), nrounds = c(50,100), max_depth = 2:3, gamma = 0, colsample_bytree = 0.8, min_child_weight = 1, subsample=Nsub)
    rf.tuneGrid <- expand.grid(mtry = seq(4,length(all.vars(formulaString))/3,by=2))
    ## fine-tune RF parameters:
	# In recent versions, caret fails if a tuneGrid is provided
	message("Starting training for random forest")
	t.mrfX <- caret::train(formulaString, data=s.train[sample.int(nrow(s.train), Nsub),], method="rf", trControl=ctrl)#, tuneGrid=rf.tuneGrid)
	gm1 <- ranger::ranger(formulaString, data=s.train, write.forest=TRUE, mtry=t.mrfX$bestTune$mtry)
	gm1.w = 1/gm1$prediction.error
	message("Starting training for xgbTree")
	gm2 <- caret::train(formulaString, data=s.train, method="xgbTree", trControl=ctrl)#, tuneGrid=gb.tuneGrid)
	gm2.w = 1/(min(gm2$results$RMSE, na.rm=TRUE)^2)
		
    v1 <- predict(gm1, test, na.action=na.pass)$predictions
    v2 <- predict(gm2, test, na.action=na.pass)
    pred <- rowSums(cbind(v1*gm1.w, v2*gm2.w))/(gm1.w+gm2.w)
	
	# Stop cluster
	parallel::stopCluster(cl)
	closeAllConnections()
	gc()
  }
  if(method=="ranger"){
    gm <- ranger::ranger(formulaString, data=s.train, write.forest=TRUE, num.trees=85)
    pred <- predict(gm, s.test, na.action = na.pass)$predictions 
  }
  obs.pred <- as.data.frame(list(s.test[,varn], pred))
  names(obs.pred) = c("Observed", "Predicted")
  obs.pred[,idcol] <- s.test[,idcol]
  obs.pred$fold = j
  return(obs.pred)
}

cv_numeric <- function(formulaString, rmatrix, nfold, idcol, cpus, method="ranger", Log=FALSE, LLO=TRUE){     
  varn = all.vars(formulaString)[1]
  message(paste("Running ", nfold, "-fold cross validation with model re-fitting method ", method," ...", sep=""))
  if(nfold > nrow(rmatrix)){ 
    stop("'nfold' argument must not exceed total number of points") 
  }
  if(sum(duplicated(rmatrix[,idcol]))>0.5*nrow(rmatrix)){
    if(LLO==TRUE){
      ## TH: Leave whole locations out
      ul <- unique(rmatrix[,idcol])
      sel.ul <- dismo::kfold(ul, k=nfold)
      sel <- lapply(1:nfold, function(o){ data.frame(row.names=which(rmatrix[,idcol] %in% ul[sel.ul==o]), x=rep(o, length(which(rmatrix[,idcol] %in% ul[sel.ul==o])))) })
      sel <- do.call(rbind, sel)
      sel <- sel[order(as.numeric(row.names(sel))),]
      message(paste0("Subsetting observations by unique location"))
    } else {
      sel <- dismo::kfold(rmatrix, k=nfold, by=rmatrix[,idcol])
      message(paste0("Subsetting observations by '", idcol, "'"))
    }
  } else {
    sel <- dismo::kfold(rmatrix, k=nfold)
    message(paste0("Simple subsetting of observations using kfolds"))
  }
  if(missing(cpus)){ 
    if(method=="randomForest"){
      cpus = nfold
    } else { 
      cpus <- parallel::detectCores(all.tests = FALSE, logical = FALSE) 
    }
  }
  if(method=="h2o"){
    out <- list()
    for(j in 1:nfold){ 
      out[[j]] <- predict_parallelP(j, sel=sel, varn=varn, formulaString=formulaString, rmatrix=rmatrix, idcol=idcol, method=method, cpus=1)
    }
  }
  if(method=="caret"){
    out <- list()
    for(j in 1:nfold){ 
      out[[j]] <- predict_parallelP(j, sel=sel, varn=varn, formulaString=formulaString, rmatrix=rmatrix, idcol=idcol, method=method, cpus=cpus)
    }
  }
  if(method=="ranger"){
    if(cpus==1){
      out <- lapply(1:nfold, function(j){predict_parallelP(j, sel=sel, varn=varn, formulaString=formulaString, rmatrix=rmatrix, idcol=idcol, method=method)})
    } else {
      require("snowfall")
      snowfall::sfInit(parallel=TRUE, cpus=ifelse(nfold>cpus, cpus, nfold))
      snowfall::sfExport("predict_parallelP","idcol","formulaString","rmatrix","sel","varn","method")
      snowfall::sfLibrary(package="plyr", character.only=TRUE)
      snowfall::sfLibrary(package="ranger", character.only=TRUE)
      out <- snowfall::sfLapply(1:nfold, function(j){predict_parallelP(j, sel=sel, varn=varn, formulaString=formulaString, rmatrix=rmatrix, idcol=idcol, method=method)})
      snowfall::sfStop()
    }
  }
  ## calculate mean accuracy:
  out <- plyr::rbind.fill(out)
  ME = mean(out$Observed - out$Predicted, na.rm=TRUE) 
  MAE = mean(abs(out$Observed - out$Predicted), na.rm=TRUE)
  RMSE = sqrt(mean((out$Observed - out$Predicted)^2, na.rm=TRUE))
  ## https://en.wikipedia.org/wiki/Coefficient_of_determination
  #R.squared = 1-sum((out$Observed - out$Predicted)^2, na.rm=TRUE)/(var(out$Observed, na.rm=TRUE)*sum(!is.na(out$Observed)))
  R.squared = 1-var(out$Observed - out$Predicted, na.rm=TRUE)/var(out$Observed, na.rm=TRUE)
  if(Log==TRUE){
    ## If the variable is log-normal then logR.squared is probably more correct
    logRMSE = sqrt(mean((log1p(out$Observed) - log1p(out$Predicted))^2, na.rm=TRUE))
    #logR.squared = 1-sum((log1p(out$Observed) - log1p(out$Predicted))^2, na.rm=TRUE)/(var(log1p(out$Observed), na.rm=TRUE)*sum(!is.na(out$Observed)))
    logR.squared = 1-var(log1p(out$Observed) - log1p(out$Predicted), na.rm=TRUE)/var(log1p(out$Observed), na.rm=TRUE)
    cv.r <- list(out, data.frame(ME=ME, MAE=MAE, RMSE=RMSE, R.squared=R.squared, logRMSE=logRMSE, logR.squared=logR.squared)) 
  } else {
    cv.r <- list(out, data.frame(ME=ME, MAE=MAE, RMSE=RMSE, R.squared=R.squared))
  }
  names(cv.r) <- c("CV_residuals", "Summary")
  return(cv.r)
  closeAllConnections()
}

## correlation plot:
pfun <- function(x,y, ...){
  panel.hexbinplot(x,y, ...)  
  panel.abline(0,1,lty=1,lw=2,col="black")
  panel.abline(0+RMSE,1,lty=2,lw=2,col="black")
  panel.abline(0-RMSE,1,lty=2,lw=2,col="black")
}

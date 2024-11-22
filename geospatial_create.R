#!/bin/Rscript
# author: James Kessler (james.kessler@noaa.gov)
# initially developed for FVCOM, Sep 2020 
# updated Sep 2023 to use SF instead of soon to be deprecated rgdal, sp, etc.
# updated again in Oct 2024 for schism polymorphism

library(sf)

#==============================================================================================
#==============================     USER    CONTROLS       ====================================
#==============================================================================================

# grid specific stuff
nhdrs <- 1           	         # number of header lines in 2dm
lk <- 'deb' 				     # prefix used for saving output files (whatever you'd like)
fin <- 'deb.2dm'                 # name of 2dm file

# geospatial stuff (if proj_native and proj_out are identical, no transform will occur)
proj_native <- '+proj=longlat +datum=WGS84' # native coordinate ref system (CRS)
proj_out <-    '+proj=longlat +datum=WGS84' # desired output CRS for shp/kml (usually lat/lon)

# glalbers for ontario grid:
#proj_native <- '+proj=aea +lat_1=42.122774 +lat_2=49.01518 +lat_0=45.568977 +lon_0=-84.455955 
#				  		+x_0=1000000 +y_0=1000000 +ellps=GRS80 +datum=NAD83 +units=m +no_defs'

gen_nodes <- T # generate nodes shapefile/kml
gen_elems <- T # generate elems shapefile/kml
gen_vor   <- T # gen voronoi polygons (slow for big grids; *REQUIRES* nodes and elems are generated)

kml_out <- F # save to kml?
shp_out <- F # save to ESRI shp?

#==============================================================================================
#==============================================================================================
#==============================================================================================




# ================= 0. set up and read in file =========================
trans_grid <- proj_out == proj_native     # shall we transform the grid?

# first read in entire file just to get element count for next step
geoms <- read.table('deb.2dm',skip=1, fill=T, colClasses=c('character',rep('numeric',6)))[,1]
num_els <- sum(grepl('E3T|E4Q', geoms))
num_nds <- sum(geoms == 'ND')
cat(sprintf('identified %i nodes and %i elements in your 2dm\n', num_nds, num_els))


# read in triangulation/quad info
options(warn=-1)
vertices <- read.table(fin,skip=nhdrs, nrow=num_els, fill=T, colClasses=c('character',rep('numeric',6)))
options(warn=0)
isquad <- vertices[,1] == 'E4Q' # logical: IS it a QUAD?
idx <- vertices[,2]

q_idx <- as.matrix(vertices[isquad,c(3,4,5,6,3)]) #quad indices
t_idx <- as.matrix(vertices[!isquad,c(3,4,5,3)])  #tri indices

nd_info <- read.table(fin, skip=nhdrs+num_els)
deps <- nd_info[,5]
crds <- nd_info[,3:4]



# ================= 1. generate st_points for NODES and save to KML/SHP file ======================================
if (gen_nodes){
	lon <- nd_info[,3]
	lat <- nd_info[,4]
	dep <- nd_info[,5]
	print('creating geospatial nodes object...')
	df <- data.frame(x=lon, y=lat, id=1:length(lat), depth_m=dep)
	nodes <- st_as_sf(df, coords=c('x','y'))
	st_crs(nodes) <- proj_native
	if(num_nds != nrow(nodes)) stop('nodes object had the wrong number of nodes, check 2DM file')
	if(trans_grid) nodes <- st_transform(nodes, proj_out)
	if (kml_out) st_write(nodes, sprintf('spatial_files/%s_nodes.kml', lk), package='sf', append=F, quiet=T)
	if (shp_out) st_write(nodes, sprintf('spatial_files/%s_nodes.shp', lk), package='sf', append=F, quiet=T)

}



#
# ================= 2. generate st_polys for elements and save to KML/SHP file ======================================

if (gen_elems){
	lonq <- matrix(crds[q_idx,1], ncol=5)
	latq <- matrix(crds[q_idx,2], ncol=5)
	lont <- matrix(crds[t_idx,1], ncol=4)
	latt <- matrix(crds[t_idx,2], ncol=4)


	print('creating geospatial elements objects:')
	print('generating quads...')
	poly_list <- list()
	for (i in 1:nrow(lonq)) poly_list[i] <- list(st_polygon(list(cbind(lonq[i,],latq[i,]))))
	quads <- st_sf(st_sfc(poly_list))
	quads$id <- idx[isquad]
	#quads$nodes <- split(q_idx[,-5], row(q_idx[,-5])) # this list works but can't be written out
	quads$nodes <- apply(q_idx[,-5], 1, function(x) paste(sprintf('%i', x), collapse=','))
	quads$depth <- apply(matrix(deps[q_idx[,-1]], ncol=4, byrow=F), 1, mean)
	quads$shape <- 'quad'

	print('generating tris...')
	poly_list <- list()
	for (i in 1:nrow(lont)) poly_list[i] <- list(st_polygon(list(cbind(lont[i,],latt[i,]))))
	tris <- st_sf(st_sfc(poly_list))
	tris$id <- idx[!isquad]
	#tris$nodes <- split(t_idx[,-4], row(t_idx[,-4])) # list works but can't be saved as kml, shp, or gpkg
	tris$nodes <- apply(cbind(t_idx[,-4],-99), 1, function(x) paste(sprintf('%i', x), collapse=','))
	tris$depth <- apply(matrix(deps[t_idx[,-1]], ncol=3, byrow=F), 1, mean)
	tris$shape <- 'tri'


	print('combining quads and tris into a single object...')
	els <- rbind(quads, tris)
	st_crs(els) <- proj_native
	if(trans_grid) els <- st_transform(els, proj_out)
	if(num_els != nrow(els)) stop('els object had the wrong number of elements, check 2DM file')
	if(kml_out) st_write(els, sprintf('spatial_files/%s_elems.kml', lk), quiet=T, append=F)
	if(shp_out) st_write(els, sprintf('spatial_files/%s_elems.shp', lk), quiet=T, append=F)
}




# ================= 3. generate Voronoi SpatialPolygons for NODES and save to KML ============================
if(gen_vor){
	print('constructing the voronoi polygons.... (slow for big grids)')
	cat(sprintf('\r step 1/3'))
	suppressMessages(water <- st_union(els, by_feature=F))
	water <- st_sf(water)
	#rm(els) # optional delete elements to save space/memory (try this if R is crashing)
	cat(sprintf('\r step 2/3'))
	vor0 <- st_voronoi(do.call(c,nodes$geometry)) #, envelope=water) envelope doesn't limit anything; sigh
	cat(sprintf('\r step 3/3\n'))
	vor <- st_sf(st_collection_extract(vor0)) 
	st_crs(vor) <- st_crs(nodes) 
	suppressMessages(sf_use_s2(FALSE)) # required for st_intersection
	suppressMessages(ii <- st_contains(vor, nodes))
	vor$id <- unlist(ii)
	st_agr(vor) <- 'constant'
	st_agr(water) <- 'constant'
	suppressMessages(vor <- st_intersection(vor, water)) # this will inadvertently SPLIT some polygons (identified later)
	vor <- vor[order(vor$id),]
	vor$depth <- nodes$depth_m
	st_agr(vor) <- 'constant'

	#	vor <- st_intersection(vor, water) # this is slow... instead find only polys that NEED intersecting (shoreline)
	suppressMessages(win <- st_contains_properly(water, vor, sparse=F))   # within
	suppressMessages(vor_fixed <- st_intersection(vor[!win,], water))
	vor <- rbind(vor[win,], vor_fixed)
	vor <- vor[order(vor$id),]
	if(num_nds != nrow(vor)) stop('vor object had the wrong number of elements, check 2DM file')
	if(kml_out) st_write(vor, sprintf('spatial_files/%s_vor.kml', lk), package='sf', append=F, quiet=T)
	if(shp_out) st_write(vor, sprintf('spatial_files/%s_vor.shp', lk), package='sf', append=F, quiet=T)
}




# optionally plot new objects for debug:
#plot(vor['depth'], lwd=.25, axes=T)
#plot(els['depth'], lwd=.25, axes=T)
#plot(els['shape'], lwd=.25, axes=T) # binary: quad or tri


# plot a subregion
els <- st_crop(els,  xmin=-75.5, xmax=-75.0, ymin=38.7, ymax=39.0)
nodes <- st_crop(nodes,  xmin=-75.5, xmax=-75.0, ymin=38.7, ymax=39.0)
vor <- st_crop(vor,  xmin=-75.5, xmax=-75.0, ymin=38.7, ymax=39.0)


par(mar=c(0,0,0,0))
plot(st_geometry(els), border='green')
plot(st_geometry(nodes), pch=20, add=T)
legend('bottomleft', legend=c('element faces', 'nodes'), col=c('green','black'), lwd=c(1,NA), pch=c(NA,20), cex=2, inset=.01)

par(mar=c(0,0,0,0))
plot(st_geometry(els), border='green')
plot(st_geometry(nodes), pch=20, add=T)
plot(st_geometry(vor), border='purple', add=T)
legend('bottomleft', legend=c('element faces', 'vornoi faces', 'nodes'), col=c('green','purple', 'black'), 
	   lwd=c(1,1,NA), pch=c(NA,NA,20), cex=2, inset=.01)


par(mar=c(0,0,0,0))
plot(st_geometry(nodes), pch=20)
plot(st_geometry(vor), border='purple', add=T)
legend('bottomleft', legend=c('Vornoi faces', 'nodes'), col=c('purple', 'black'), lwd=c(1,NA), pch=c(NA,20), cex=2, inset=.01)


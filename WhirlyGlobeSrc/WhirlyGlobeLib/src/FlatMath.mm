/*
 *  FlatMath.mm
 *  WhirlyGlobeLib
 *
 *  Created by Steve Gifford on 1/10/12.
 *  Copyright 2011 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "FlatMath.h"
#import "GlobeMath.h"

namespace WhirlyKit
{
    
GeoCoord PlateCarreeCoordSystem::localToGeographic(Point3f pt)
{
    return GeoCoord(pt.x(),pt.y());
}

Point3f PlateCarreeCoordSystem::geographicToLocal(GeoCoord geo)
{
    return Point3f(geo.lon(),geo.lat(),0.0);
}
    
Point3f PlateCarreeCoordSystem::localToGeocentricish(Point3f pt)
{
    return GeoCoordSystem::LocalToGeocentricish(localToGeographic(pt));
}
    
Point3f PlateCarreeCoordSystem::geocentricishToLocal(Point3f pt)
{
    Point3f coord = GeoCoordSystem::GeocentricishToLocal(pt);
    return geographicToLocal(GeoCoord(coord.x(),coord.y()));
}    

}
